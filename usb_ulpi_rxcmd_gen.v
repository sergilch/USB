//-----------------------------------------------------------------------------
// usb_ulpi_rxcmd_gen.v
//
// "RXCMD Generator" of the ULPI Interface Controller (PHY side).
//
// RXCMD byte (sent with NXT = 0 while DIR = 1):
//   [1:0] LineState   [3:2] VbusState   [5:4] RxEvent   [6] ID   [7] ALT_INT
//   RxEvent: 00 RxActive = 0 / RxError = 0,  01 RxActive,  11 RxActive + RxError,
//            10 HostDisconnect (only when RxActive = 0)
//   VbusState: 00 VBUS < SessEnd, 01 SessEnd..SessValid, 10 SessValid..VbusValid,
//              11 >= VbusValid
//
// The block keeps a shadow register of the last RXCMD that went out and compares the
// byte that would be sent now (cmd_now) against it.  An RXCMD is requested (rxcmd_req)
// when
//   * LineState or ALT_INT changed                          (always),
//   * RxActive or RxError changed                           (always: packet framing),
//   * HostDisconnect, a VBUS threshold (VbusValid / SessValid / SessEnd) or IdGnd
//     changed in a direction that is enabled in the USB Interrupt Enable registers
//     (ie_rise / ie_fall, bit order as in the registers: [0] HostDisconnect,
//     [1] VbusValid, [2] SessValid, [3] SessEnd, [4] IdGnd).
// Masked changes are not reported on their own, but the next RXCMD that goes out for any
// reason carries the current values.  The comparison is against what the Link was told
// last, so an excursion that returns to the already reported value produces no RXCMD.
//
// The arbiter sends cmd_now (the current values, not a snapshot taken at the trigger),
// and pulses cmd_taken in the tick it is consumed; the shadow register is then updated.
// sent_rxev (RxEvent field of the shadow register) tells the RX Data Handler that the
// RxActive / RxError announcement has reached the Link.
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_rxcmd_gen (
    input  wire        clk,
    input  wire        rst_n,         // async assert, sync release
    input  wire        ce,

    // status inputs (synchronous to the tick clock)
    input  wire [1:0]  linestate,
    input  wire [1:0]  vbusstate,
    input  wire        host_disc,     // HS host disconnect
    input  wire        id_gnd,
    input  wire        alt_int,

    // RX Data Handler
    input  wire        rxa,
    input  wire        rxe,

    // USB Interrupt Enable registers (from the Register File)
    input  wire [4:0]  ie_rise,
    input  wire [4:0]  ie_fall,

    // arbiter
    input  wire        cmd_taken,     // the RXCMD is consumed in this tick (includes ce)
    output wire [7:0]  cmd_now,
    output wire        rxcmd_req,
    output wire [1:0]  sent_rxev
);

    reg [7:0] last_r;                 // last RXCMD that was sent

    wire [1:0] ev_now = rxa ? (rxe ? 2'b11 : 2'b01) : (host_disc ? 2'b10 : 2'b00);

    assign cmd_now   = {alt_int, id_gnd, ev_now, vbusstate, linestate};
    assign sent_rxev = last_r[5:4];

    // fields of the current and of the last sent byte
    wire [1:0] ev_c = cmd_now[5:4];
    wire [1:0] ev_l = last_r[5:4];
    wire       act_c = ev_c[0],         act_l = ev_l[0];
    wire       err_c = (ev_c == 2'b11), err_l = (ev_l == 2'b11);
    wire       hd_c  = (ev_c == 2'b10), hd_l  = (ev_l == 2'b10);

    wire [1:0] vb_c = cmd_now[3:2];
    wire [1:0] vb_l = last_r[3:2];
    wire       vv_c = (vb_c == 2'b11), vv_l = (vb_l == 2'b11);   // VbusValid
    wire       sv_c = vb_c[1],         sv_l = vb_l[1];           // SessValid
    wire       se_c = (vb_c == 2'b00), se_l = (vb_l == 2'b00);   // SessEnd

    wire       id_c = cmd_now[6], id_l = last_r[6];

    assign rxcmd_req =
           (cmd_now[1:0] != last_r[1:0])                    // LineState
        || (cmd_now[7]   != last_r[7])                      // ALT_INT
        || (act_c != act_l) || (err_c != err_l)             // RxActive / RxError
        || (hd_c && !hd_l && ie_rise[0]) || (!hd_c && hd_l && ie_fall[0])
        || (vv_c && !vv_l && ie_rise[1]) || (!vv_c && vv_l && ie_fall[1])
        || (sv_c && !sv_l && ie_rise[2]) || (!sv_c && sv_l && ie_fall[2])
        || (se_c && !se_l && ie_rise[3]) || (!se_c && se_l && ie_fall[3])
        || (id_c && !id_l && ie_rise[4]) || (!id_c && id_l && ie_fall[4]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            last_r <= 8'h00;
        else if (ce && cmd_taken)
            last_r <= cmd_now;
    end

endmodule
