//-----------------------------------------------------------------------------
// usb_ulpi_reg_file.v
//
// ULPI Register File of the USB 2.0 PHY (immediate register set 00h-3Fh), the block
// that usb_ulpi_reg_access reads and writes.
//
//   usb_ulpi_reg_access --reg_*--> [THIS BLOCK] --> config outputs (mode / termination,
//                                       ^                 interface, OTG, interrupt masks)
//   line / VBUS / ID status ------------+
//
// Register map (addresses as in ULPI 1.1; RW registers have a SET alias at +1 and a CLR
// alias at +2: write = value, set = q OR value, clear = q AND NOT value; every address of
// the group reads the register value)
//   00h-03h  Vendor ID low / high, Product ID low / high      RO constants (parameters)
//   04h-06h  Function Control    reset 45h
//              [1:0] XcvrSelect  [2] TermSelect  [4:3] OpMode  [5] Reset (self-clearing,
//              generates the one-tick pulse soft_reset)  [6] SuspendM  [7] reserved
//   07h-09h  Interface Control   reset 00h   (8 RW bits, passed on as ifc_ctrl)
//   0Ah-0Ch  OTG Control         reset 06h   (8 RW bits, passed on as otg_ctrl)
//   0Dh-0Fh  USB Interrupt Enable Rising    reset 1Fh   [4:0] HostDisconnect, VbusValid,
//   10h-12h  USB Interrupt Enable Falling   reset 1Fh   SessValid, SessEnd, IdGnd
//   13h      USB Interrupt Status   RO  live (synchronized) status, same bit order
//   14h      USB Interrupt Latch    RO, cleared by a read; bit set on an enabled rising /
//                                   falling edge of the status bit (an event in the tick
//                                   of a read is not lost)
//   15h      Debug                  RO  [1:0] LineState (synchronized)
//   16h-18h  Scratch                reset 00h
//   other addresses, and the whole extended set (reg_ext = 1): read 00h, writes ignored
//   (Carkit and vendor-specific registers are not implemented)
//   Reserved bits read 0 and ignore writes.
//
// Register access interface (as in usb_ulpi_reg_access): reg_wr / reg_rd are one-tick
// pulses; a read is answered one tick later with rd_valid (one tick) and reg_rdata.
//
// Status inputs go through a 2-FF synchronizer; the status register shows the
// synchronized value.  VID / PID default to the USB3320 values (0424h / 0007h) - override
// them for the ASIC.
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_reg_file #(
    parameter [7:0] VID_L = 8'h24,
    parameter [7:0] VID_H = 8'h04,
    parameter [7:0] PID_L = 8'h07,
    parameter [7:0] PID_H = 8'h00
) (
    input  wire        clk,
    input  wire        rst_n,         // async assert, sync release
    input  wire        ce,

    // register access (usb_ulpi_reg_access)
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire        reg_ext,
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_wdata,
    output reg  [7:0]  reg_rdata,
    output reg         rd_valid,

    // status inputs
    input  wire        host_disc,
    input  wire        a_vbus_vld,    // VbusValid
    input  wire        sess_vld,      // SessValid
    input  wire        sess_end,      // SessEnd
    input  wire        id_gnd,
    input  wire [1:0]  linestate,

    // configuration outputs
    output wire [1:0]  xcvrselect,
    output wire        termselect,
    output wire [1:0]  opmode,
    output wire        suspendm,
    output wire        soft_reset,    // one tick after a write of Reset = 1
    output wire [7:0]  ifc_ctrl,
    output wire [7:0]  otg_ctrl,
    output wire [4:0]  ie_rise,
    output wire [4:0]  ie_fall
);

    localparam [7:0] A_FC  = 8'h04;
    localparam [7:0] A_IC  = 8'h07;
    localparam [7:0] A_OTG = 8'h0A;
    localparam [7:0] A_IER = 8'h0D;
    localparam [7:0] A_IEF = 8'h10;
    localparam [7:0] A_SCR = 8'h16;

    localparam [7:0] FC_MASK  = 8'h5F;      // bit 5 (Reset) handled separately, bit 7 reserved
    localparam [7:0] IE_MASK  = 8'h1F;

    reg [7:0] fc_q, ic_q, otg_q, ier_q, ief_q, scr_q;
    reg       reset_q;
    reg [4:0] s0, s1, sp;                   // status synchronizer and previous value
    reg [1:0] l0, l1;
    reg [4:0] latch_q;

    // ---------------- write decode (immediate set only) ----------------
    wire wr_i = reg_wr && !reg_ext;

    wire [7:0] d_fc  = reg_addr - A_FC;
    wire [7:0] d_ic  = reg_addr - A_IC;
    wire [7:0] d_otg = reg_addr - A_OTG;
    wire [7:0] d_ier = reg_addr - A_IER;
    wire [7:0] d_ief = reg_addr - A_IEF;
    wire [7:0] d_scr = reg_addr - A_SCR;

    wire hit_fc  = (reg_addr >= A_FC)  && (reg_addr <= A_FC  + 8'd2);
    wire hit_ic  = (reg_addr >= A_IC)  && (reg_addr <= A_IC  + 8'd2);
    wire hit_otg = (reg_addr >= A_OTG) && (reg_addr <= A_OTG + 8'd2);
    wire hit_ier = (reg_addr >= A_IER) && (reg_addr <= A_IER + 8'd2);
    wire hit_ief = (reg_addr >= A_IEF) && (reg_addr <= A_IEF + 8'd2);
    wire hit_scr = (reg_addr >= A_SCR) && (reg_addr <= A_SCR + 8'd2);

    // op: 0 write, 1 set, 2 clear
    function [7:0] upd;
        input [7:0] q;
        input [7:0] w;
        input [1:0] op;
        input [7:0] mask;
        begin
            case (op)
                2'd0:    upd = w & mask;
                2'd1:    upd = (q | w) & mask;
                default: upd = q & ~w;
            endcase
        end
    endfunction

    // ---------------- status, edges, latch ----------------
    wire [4:0] stat_in = {id_gnd, sess_end, sess_vld, a_vbus_vld, host_disc};
    wire [4:0] rise    = s1 & ~sp;
    wire [4:0] fall    = ~s1 & sp;
    wire [4:0] evt     = (rise & ier_q[4:0]) | (fall & ief_q[4:0]);

    // ---------------- read mux ----------------
    wire [7:0] a = reg_addr;
    reg  [7:0] rmux;

    always @* begin
        rmux = 8'h00;
        if (!reg_ext) begin
            if      (a == 8'h00) rmux = VID_L;
            else if (a == 8'h01) rmux = VID_H;
            else if (a == 8'h02) rmux = PID_L;
            else if (a == 8'h03) rmux = PID_H;
            else if (hit_fc)     rmux = fc_q | {2'b00, reset_q, 5'b00000};
            else if (hit_ic)     rmux = ic_q;
            else if (hit_otg)    rmux = otg_q;
            else if (hit_ier)    rmux = ier_q;
            else if (hit_ief)    rmux = ief_q;
            else if (a == 8'h13) rmux = {3'b000, s1};
            else if (a == 8'h14) rmux = {3'b000, latch_q};
            else if (a == 8'h15) rmux = {6'b000000, l1};
            else if (hit_scr)    rmux = scr_q;
        end
    end

    wire rd_latch = reg_rd && !reg_ext && (a == 8'h14);

    // ---------------- registers ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fc_q      <= 8'h45;
            ic_q      <= 8'h00;
            otg_q     <= 8'h06;
            ier_q     <= 8'h1F;
            ief_q     <= 8'h1F;
            scr_q     <= 8'h00;
            reset_q   <= 1'b0;
            s0        <= 5'd0;
            s1        <= 5'd0;
            sp        <= 5'd0;
            l0        <= 2'd0;
            l1        <= 2'd0;
            latch_q   <= 5'd0;
            reg_rdata <= 8'd0;
            rd_valid  <= 1'b0;
        end else if (ce) begin
            // synchronizer, edge detector
            s0 <= stat_in;
            s1 <= s0;
            sp <= s1;
            l0 <= linestate;
            l1 <= l0;

            // interrupt latch: events win over the clear-on-read
            latch_q <= (rd_latch ? 5'd0 : latch_q) | evt;

            // Function Control: Reset is a self-clearing request
            reset_q <= 1'b0;
            if (wr_i && hit_fc) begin
                fc_q <= upd(fc_q, reg_wdata, d_fc[1:0], FC_MASK);
                if ((d_fc[1:0] != 2'd2) && reg_wdata[5])
                    reset_q <= 1'b1;
            end
            if (wr_i && hit_ic)  ic_q  <= upd(ic_q,  reg_wdata, d_ic[1:0],  8'hFF);
            if (wr_i && hit_otg) otg_q <= upd(otg_q, reg_wdata, d_otg[1:0], 8'hFF);
            if (wr_i && hit_ier) ier_q <= upd(ier_q, reg_wdata, d_ier[1:0], IE_MASK);
            if (wr_i && hit_ief) ief_q <= upd(ief_q, reg_wdata, d_ief[1:0], IE_MASK);
            if (wr_i && hit_scr) scr_q <= upd(scr_q, reg_wdata, d_scr[1:0], 8'hFF);

            // read answer, one tick later
            rd_valid <= reg_rd;
            if (reg_rd)
                reg_rdata <= rmux;
        end
    end

    // ---------------- outputs ----------------
    assign xcvrselect = fc_q[1:0];
    assign termselect = fc_q[2];
    assign opmode     = fc_q[4:3];
    assign suspendm   = fc_q[6];
    assign soft_reset = reset_q;
    assign ifc_ctrl   = ic_q;
    assign otg_ctrl   = otg_q;
    assign ie_rise    = ier_q[4:0];
    assign ie_fall    = ief_q[4:0];

endmodule
