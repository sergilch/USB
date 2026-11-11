//-----------------------------------------------------------------------------
// usb_mode_term_ctrl.v
//
// "Mode / Termination Control" of the USB 2.0 PHY (WORK_PLAN 3.3 / 3.4,
// AFE_INTEGRATION_PLAN.md phase A6).  Position:
//
//   usb_ulpi_reg_file (Function Control: XcvrSelect, TermSelect, OpMode;
//                      OTG Control: DpPulldown, DmPulldown)
//     --> [THIS BLOCK] --> pull-up / termination / pull-down enables (AFE pins,
//                          DOC/afe_interface_spec.md 3.5)
//                      --> TX framing controls (usb_tx_datapath / usb_tx_path)
//                      --> drv_dis (usb_afe_tx_if), host_mode (usb_line_state)
//
// Termination decode (USB3320 Table 5-1, ULPI 1.1 Table 41).  host = DpPulldown
// and DmPulldown both set (a downstream port has both 15 kOhm pull-downs on):
//
//   OpMode 01 (non-driving)            everything off, pull-downs included
//   dp_pulldown_en / dm_pulldown_en    = DpPulldown / DmPulldown
//   hs_term_en  (45 Ohm on DP and DM)  = XcvrSelect 00 and TermSelect 0
//                                        (host and peripheral HS, host chirp,
//                                        test J / K)
//   dp_pullup_en (1.5 kOhm on DP)      = peripheral and TermSelect 1 and
//                                        XcvrSelect != 10 (FS, FS-for-LS, HS chirp,
//                                        FS suspend / resume)
//   dm_pullup_en (1.5 kOhm on DM)      = peripheral and TermSelect 1 and
//                                        XcvrSelect 10 (LS peripheral; optional in
//                                        ULPI, a proposed optional AFE pin)
//   Rows of Table 5-1 are reproduced exactly; combinations outside it follow the
//   same formulas (the USB3320 falls back to its last row instead).  In
//   particular a peripheral keeps its pull-up through XcvrSelect 00 with
//   TermSelect 1, so a two-step register update can't make it look detached.
//
// Switching order: the outputs are registered and change on ce60 only.  When an
//   update turns some enables off and others on (FS -> HS: pull-up off, 45 Ohm
//   on; HS -> FS suspend: the reverse), the ones going off switch first, and no
//   enable goes on earlier than BBM_TK ticks after the last one went off (break
//   before make), so the pull-up and the HS terminations are never on together,
//   also when the Link changes the registers twice in a row.  Turning only
//   things off takes one tick; turning things on takes one tick when nothing
//   went off in the last BBM_TK ticks.
//   rst_n and iso_en (power sequencer: isolation) put all enables off at once
//   (spec 3.5 reset / isolated values: 0); after iso_en falls the outputs come
//   back through the normal path (one tick).
//
// TX framing controls (combinational from the registers; the TX path samples
//   them when a packet starts).  Decision D4 of WORK_PLAN.md, from ULPI 1.1
//   3.8.2.3 / 3.8.5:
//   tx_bypass   = OpMode 10: no bit stuffing, no NRZI (chirp, resume K,
//                 test J / K); the data bits are line levels (1 = J, 0 = K).
//   tx_sync_dis = OpMode 10: no SYNC (the Link sends NOPID + 00h / FFh).
//   tx_eop_dis  = OpMode 10, except for a host at FS / LS: ULPI 1.1 3.8.5.3,
//                 the host PHY appends the FS / LS EOP (SE0 2 bits, J 1 bit) to
//                 the resume K "because DpPulldown and DmPulldown are set";
//                 chirps, a peripheral's remote-wakeup K and HS test J / K end
//                 without EOP.
//   drv_dis     = OpMode 01 (non-driving): drivers off (usb_afe_tx_if clamp).
//   OpMode 11 (optional in ULPI: no automatic SYNC / EOP, NRZI and stuffing
//   kept) is not supported and transmits like OpMode 00.
//
// Clocking: clk_bit with ce60; active-low asynchronous reset.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_mode_term_ctrl #(
    parameter BBM_TK = 2              // ticks between "off" and "on" (1..15)
) (
    input  wire       clk_bit,
    input  wire       rst_n,
    input  wire       ce60,

    // register file (quasi-static)
    input  wire [1:0] xcvrselect,
    input  wire       termselect,
    input  wire [1:0] opmode,
    input  wire       dp_pulldown,    // OTG Control bit 1
    input  wire       dm_pulldown,    // OTG Control bit 2

    input  wire       iso_en,         // isolation: all enables off

    // termination / pull enables (AFE pins, registered)
    output wire       dp_pullup_en,
    output wire       dm_pullup_en,
    output wire       hs_term_en,
    output wire       dp_pulldown_en,
    output wire       dm_pulldown_en,
    output wire       term_busy,      // a break-before-make gap is running

    // TX framing / driver control
    output wire       tx_bypass,
    output wire       tx_sync_dis,
    output wire       tx_eop_dis,
    output wire       drv_dis,
    output wire       host_mode
);

    wire host  = dp_pulldown && dm_pulldown;
    wire ndrv  = (opmode == 2'b01);
    wire fsls  = (xcvrselect != 2'b00);

    // target: {dp_pullup, dm_pullup, hs_term, dp_pd, dm_pd}
    wire [4:0] tgt = ndrv ? 5'b00000 : {
        !host && termselect && (xcvrselect != 2'b10),
        !host && termselect && (xcvrselect == 2'b10),
        (xcvrselect == 2'b00) && !termselect,
        dp_pulldown,
        dm_pulldown };

    reg [4:0] cur;
    reg [3:0] gap;                    // ticks left before "on" bits may follow

    wire [4:0] off_bits = cur & ~tgt;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            cur <= 5'b00000;
            gap <= 4'd0;
        end else if (iso_en) begin
            cur <= 5'b00000;
            gap <= 4'd0;
        end else if (ce60) begin
            if (off_bits != 5'b00000) begin
                cur <= cur & tgt;                       // break
                gap <= BBM_TK - 1;
            end else if (gap != 4'd0)
                gap <= gap - 4'd1;
            else
                cur <= tgt;                             // make
        end
    end

    assign {dp_pullup_en, dm_pullup_en, hs_term_en, dp_pulldown_en, dm_pulldown_en} = cur;
    assign term_busy = (cur != tgt) && !iso_en;

    assign tx_bypass   = (opmode == 2'b10);
    assign tx_sync_dis = (opmode == 2'b10);
    assign tx_eop_dis  = (opmode == 2'b10) && !(host && fsls);
    assign drv_dis     = ndrv;
    assign host_mode   = host;

endmodule
