//-----------------------------------------------------------------------------
// usb_afe_trim_regs.v - AFE trim / test / power-status registers (ULPI vendor
//                       registers 30h-3Fh)
//
// WORK_PLAN 6.4 / 6.6, AFE_INTEGRATION_PLAN.md phase A7, DOC/afe_interface_spec.md
// 3.6 and 6.  Position:
//
//   usb_ulpi_reg_file --vnd_*--> [THIS BLOCK] --> trim_* (AFE TRIM pins and the
//     (30h-3Fh, also ext 30h-3Fh)       |          digital TX_LEAD / TX_LAG /
//                                       |          LOCK_DLY / SQ_COMP), atb_sel,
//   pwr_seq / lock-detector status -----+          ana_lpbk, lol_clr
//
// Register map (one address per register: no set / clear aliases, unlike the
// ULPI registers; reserved bits read 0, writes to them are ignored)
//   30h  TRIM_TX    [3:0] TX_AMP   (8)   HS driver current      [6:4] HS_TERM (4)
//   31h  TRIM_LEAD  [4:0] TX_LEAD  (10)  TX_EN lead, bit times  [7:5] TX_LAG  (0)
//   32h  TRIM_RX    [2:0] RX_VTH   (4)   [5:3] RX_HYST (4)      HS / FS receiver
//   33h  TRIM_SQ    [2:0] SQ_VTH   (4)   [5:3] DISC_VTH (4)     squelch / disconnect
//   34h  TRIM_CDR   [2:0] CDR_ICP  (4)   [4:3] CDR_BAND (1)
//   35h  TRIM_PLL   [2:0] PLL_ICP  (4)
//   36h  TRIM_DLY   [2:0] LOCK_DLY (2)   [5:3] SQ_COMP  (0)     usb_afe_rx_if
//   37h-3Bh         reserved (read 00h)
//   3Ch  TEST       [3:0] ATB_SEL  (0)   [4] ANA_LPBK (0)       immediate (no shadow)
//   3Dh  PWR_STAT   RO: [3:0] power-sequencer state, [4] pll_lock, [5] pll_err,
//                   [6] lol (loss of lock, sticky).  Writing 1 to bit 6 clears
//                   lol (lol_clr, one ce tick).
//   3Eh  TRIM_CTRL  [0] UPDATE: write 1 copies the shadow set 30h-36h into the
//                   active set (self-clearing, reads 0).  [1] RDACT: reads of
//                   30h-36h return the active set instead of the shadow set.
//                   [7] RO: shadow differs from the active set.
//   3Fh             reserved
//   Defaults (in brackets) are parameters; the spec's widths are proposals
//   (Q11), so are the defaults except TX_LEAD (A2), LOCK_DLY / SQ_COMP (A3).
//
// Shadow / active: writes go to the shadow set; the AFE and the digital see
//   only the active set, which changes all at once on UPDATE (one ce tick), so
//   a multi-register trim change never shows an intermediate combination.
//   Both sets reset to the defaults.  usb_afe_tx_if takes over TX_LEAD /
//   TX_LAG only while it is idle; the analog trims are static levels.
//
// Status inputs (pwr_state, pll_err: ref_clk domain; pll_lock, lol: clk_bit):
//   2-FF synchronized on clk_bit; PWR_STAT updates only when two consecutive
//   synchronized samples agree, so a read never shows a half-changed state code.
//
// Access interface (from usb_ulpi_reg_file):
//   vnd_wr is a one-tick write pulse, vnd_addr = address[3:0]; vnd_rdata is
//   combinational from vnd_addr (the fixed ULPI read timing needs the value in
//   the turnaround tick).  Reads have no side effect.
//
// Clocking: clk_bit with the tick enable ce (ce60).  rst_n: the core reset.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_afe_trim_regs #(
    parameter [7:0] D_TX   = 8'h48,   // HS_TERM 4, TX_AMP 8
    parameter [7:0] D_LEAD = 8'h0A,   // TX_LAG 0, TX_LEAD 10
    parameter [7:0] D_RX   = 8'h24,   // RX_HYST 4, RX_VTH 4
    parameter [7:0] D_SQ   = 8'h24,   // DISC_VTH 4, SQ_VTH 4
    parameter [7:0] D_CDR  = 8'h0C,   // CDR_BAND 1, CDR_ICP 4
    parameter [7:0] D_PLL  = 8'h04,   // PLL_ICP 4
    parameter [7:0] D_DLY  = 8'h02    // SQ_COMP 0, LOCK_DLY 2
) (
    input  wire       clk_bit,
    input  wire       rst_n,
    input  wire       ce,

    // access (usb_ulpi_reg_file)
    input  wire       vnd_wr,
    input  wire [3:0] vnd_addr,
    input  wire [7:0] vnd_wdata,
    output reg  [7:0] vnd_rdata,

    // status
    input  wire [3:0] pwr_state,
    input  wire       pll_err,
    input  wire       pll_lock,
    input  wire       lol,
    output reg        lol_clr,

    // active trims
    output wire [3:0] trim_tx_amp,
    output wire [2:0] trim_hs_term,
    output wire [4:0] trim_tx_lead,
    output wire [2:0] trim_tx_lag,
    output wire [2:0] trim_rx_vth,
    output wire [2:0] trim_rx_hyst,
    output wire [2:0] trim_sq_vth,
    output wire [2:0] trim_disc_vth,
    output wire [2:0] trim_cdr_icp,
    output wire [1:0] trim_cdr_band,
    output wire [2:0] trim_pll_icp,
    output wire [2:0] trim_lock_dly,
    output wire [2:0] trim_sq_comp,

    // test
    output wire [3:0] atb_sel,
    output wire       ana_lpbk
);

    // writable bits per trim register (30h-36h)
    localparam [55:0] MASK = {8'h3F, 8'h07, 8'h1F, 8'h3F, 8'h3F, 8'hFF, 8'h7F};
    localparam [55:0] DEF  = {D_DLY, D_PLL, D_CDR, D_SQ, D_RX, D_LEAD, D_TX};

    reg [55:0] shd, act;           // byte k = register 30h + k
    reg [4:0]  test_q;
    reg        rdact;
    reg [6:0]  st0, st1, st2, stat;

    wire       is_trim = (vnd_addr <= 4'h6);

    // ---------------- read mux (combinational) ----------------
    wire [55:0] rset = rdact ? act : shd;
    always @* begin
        vnd_rdata = 8'h00;
        if (is_trim)                vnd_rdata = rset[vnd_addr[2:0]*8 +: 8];
        else if (vnd_addr == 4'hC)  vnd_rdata = {3'b000, test_q};
        else if (vnd_addr == 4'hD)  vnd_rdata = {1'b0, stat};
        else if (vnd_addr == 4'hE)  vnd_rdata = {(shd != act), 5'b00000, rdact, 1'b0};
    end

    // ---------------- registers ----------------
    integer k;
    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            shd     <= DEF & MASK;
            act     <= DEF & MASK;
            test_q  <= 5'd0;
            rdact   <= 1'b0;
            lol_clr <= 1'b0;
            st0     <= 7'd0;
            st1     <= 7'd0;
            st2     <= 7'd0;
            stat    <= 7'd0;
        end else begin
            st0 <= {lol, pll_err, pll_lock, pwr_state};
            st1 <= st0;
            if (ce) begin
                st2 <= st1;
                if (st1 == st2) stat <= st1;
                lol_clr <= 1'b0;
                if (vnd_wr) begin
                    for (k = 0; k < 7; k = k + 1)
                        if ({28'd0, vnd_addr} == k)
                            shd[k*8 +: 8] <= vnd_wdata & MASK[k*8 +: 8];
                    if (vnd_addr == 4'hC) test_q <= vnd_wdata[4:0];
                    if (vnd_addr == 4'hD) lol_clr <= vnd_wdata[6];
                    if (vnd_addr == 4'hE) begin
                        rdact <= vnd_wdata[1];
                        if (vnd_wdata[0]) act <= shd;
                    end
                end
            end
        end
    end

    // ---------------- outputs (active set) ----------------
    assign trim_tx_amp   = act[3:0];
    assign trim_hs_term  = act[6:4];
    assign trim_tx_lead  = act[12:8];
    assign trim_tx_lag   = act[15:13];
    assign trim_rx_vth   = act[18:16];
    assign trim_rx_hyst  = act[21:19];
    assign trim_sq_vth   = act[26:24];
    assign trim_disc_vth = act[29:27];
    assign trim_cdr_icp  = act[34:32];
    assign trim_cdr_band = act[36:35];
    assign trim_pll_icp  = act[42:40];
    assign trim_lock_dly = act[50:48];
    assign trim_sq_comp  = act[53:51];
    assign atb_sel       = test_q[3:0];
    assign ana_lpbk      = test_q[4];

endmodule
