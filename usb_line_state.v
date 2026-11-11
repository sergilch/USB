//-----------------------------------------------------------------------------
// usb_line_state.v
//
// "Line State / Event Detector" of the USB 2.0 PHY (WORK_PLAN 3.2,
// AFE_INTEGRATION_PLAN.md phase A5).  Replaces the linestate / host_disc
// top-level inputs of usb_ulpi_phy_top.  Position:
//
//   AFE --> usb_rx_status_sync --rxdp_s, rxdm_s, rxrcv_s, squelch_s, disc_s-->
//       [THIS BLOCK] --linestate[1:0], host_disc--> usb_ulpi_phy_top
//                                                   (RXCMD, ULPI Debug register)
//
// LineState encoding (UTMI+ / ULPI 1.1, Table 7 and Fig. 12; USB3320 Note 6-1):
//   bit 0 = D+ single-ended receiver, bit 1 = D- single-ended receiver
//   00 SE0, 01 J at FS (D+ high) / K at LS, 10 K at FS / J at LS, 11 SE1.
//
// Mode (quasi-static, from the Function Control register):
//   FS / LS   XcvrSelect 01 / 10 / 11:  raw = {rxdm_s, rxdp_s}.
//   HS        XcvrSelect 00, OpMode != 10:  raw = squelch_s ? 00 : 01
//             (squelch = SE0, !squelch = J; ULPI Fig. 12: the HS EOP after a
//             transmit is the !squelch -> squelch transition).
//   Chirp     XcvrSelect 00, OpMode 10:  raw = squelch_s ? 00 :
//             (rxrcv_s ? 01 (J) : 10 (K)).  ULPI 1.1 note 11: chirp reception
//             uses the differential receiver qualified by squelch, so that the
//             800 mV chirps (below the 0.8-2.0 V single-ended thresholds) and
//             idle noise give no false bus activity.  rxrcv is the FS/LS
//             differential receiver (200 mV sensitivity), which is on in all
//             modes.
//
// Filtering (ULPI 1.1 section 2 / UTMI+): SE0 / SE1 caused by D+ / D- skew must
//   not reach LineState.  raw is sampled on every ce60 tick:
//   * FS / LS, raw = J or K: shown at once (in the same tick);
//   * FS / LS, raw = SE0 or SE1: shown once raw has held it on SE_FS (2) /
//     SE_LS (14) consecutive ticks (UTMI clocks); LS is XcvrSelect 10 only, 11
//     uses the FS filter;
//   * chirp: every new value needs CH_TK (2) consecutive ticks (chirps last
//     40-60 us);
//   * HS: shown at once (usb_rx_status_sync filters squelch).
//   Until a new value qualifies, the previous LineState is held.  So a skew
//   glitch shorter than one tick is never shown, and a J -> SE0 -> K crossover
//   reads J, K.
//
//   Latency from the line (receiver output) to linestate: 2 cycles of
//   synchronizer + up to 8 cycles until the next tick = at most 1.25 ticks for
//   J / K and HS; plus (SE_FS - 1) or (SE_LS - 1) ticks for SE0 / SE1.  ULPI 1.1:
//   LineState within 2-3 clocks of D+ / D-; the RXCMD adds the rest.
//
// HostDisconnect (USB 2.0 7.1.7.3, USB3320 6.2.5.1): a host samples the
//   disconnect detector during the HS EOP it transmits; the doubled amplitude
//   (800 mV, no far-end termination) shows a detached device.  Here:
//   * evaluated in host mode only (host_mode = 1: OTG Control DpPulldown and
//     DmPulldown, the 15 kOhm pull-downs of a downstream port) at HS
//     (XcvrSelect 00) with OpMode 00 (normal; chirps are 800 mV by design);
//   * disc_s is ORed over the transmit window: from hs_tx_act (tx_active of
//     usb_afe_tx_if: TX_EN high at the pins, including lead / lag) rising until
//     DISC_TAIL clk_bit cycles after it falls, to cover the delay of the AFE
//     detector and of the synchronizer;
//   * at the end of the window, host_disc takes the result (on the next tick).
//     So it is updated once per transmitted packet (every SOF, 125 us) and holds
//     in between.  It is cleared when the port leaves HS host mode.
//   The window is the whole packet, not just the EOP: with a device attached
//   the near end sees 400 mV for the whole packet (the line looks like 45 Ohm
//   until the far-end termination answers, which matches), and a detached
//   device doubles the level within one round trip.  So sampling the whole
//   packet detects the same disconnects, only sooner; it needs no EOP signal
//   from the serializer.
//
// Outputs change on ce60 only (ULPI-domain signals, 8-cycle multicycle paths).
// Not here yet: low-power mode (combinational LineState on DATA[1:0], ULPI
// 3.9), resume / reset event detection for wake-up (WORK_PLAN 5.6).
//
// Clocking: clk_bit with ce60; active-low asynchronous reset.  Reset value:
//   linestate = 00 (SE0, the isolated receiver value), host_disc = 0.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_line_state #(
    parameter SE_FS     = 2,          // ticks an SE0 / SE1 must hold, FS
    parameter SE_LS     = 14,         // ticks an SE0 / SE1 must hold, LS
    parameter CH_TK     = 2,          // ticks a chirp-mode value must hold
    parameter DISC_TAIL = 32          // clk_bit cycles of the window after TX (1..63)
) (
    input  wire       clk_bit,
    input  wire       rst_n,
    input  wire       ce60,

    // from usb_rx_status_sync (clk_bit domain)
    input  wire       rxdp_s,
    input  wire       rxdm_s,
    input  wire       rxrcv_s,
    input  wire       squelch_s,
    input  wire       disc_s,

    // mode (register file, quasi-static)
    input  wire [1:0] xcvrselect,
    input  wire [1:0] opmode,
    input  wire       host_mode,      // DpPulldown & DmPulldown

    // local HS transmitter (usb_afe_tx_if tx_active)
    input  wire       hs_tx_act,

    output reg  [1:0] linestate,
    output reg        host_disc
);

    // ---------------- LineState ----------------
    wire is_hs    = (xcvrselect == 2'b00);
    wire is_chirp = is_hs && (opmode == 2'b10);
    wire is_ls    = (xcvrselect == 2'b10);

    reg [1:0] raw;
    always @* begin
        if (is_chirp)   raw = squelch_s ? 2'b00 : (rxrcv_s ? 2'b01 : 2'b10);
        else if (is_hs) raw = squelch_s ? 2'b00 : 2'b01;
        else            raw = {rxdm_s, rxdp_s};
    end

    // consecutive ticks on which raw had the value of raw_q (saturating)
    reg  [1:0] raw_q;
    reg  [3:0] run;
    wire [3:0] run_n = (raw != raw_q) ? 4'd1 : ((run == 4'd15) ? run : run + 4'd1);

    wire       se    = (raw == 2'b00) || (raw == 2'b11);
    wire [3:0] need  = is_chirp ? CH_TK :
                       is_hs    ? 4'd1  :
                       !se      ? 4'd1  :
                       is_ls    ? SE_LS : SE_FS;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            raw_q     <= 2'b00;
            run       <= 4'd0;
            linestate <= 2'b00;
        end else if (ce60) begin
            raw_q <= raw;
            run   <= run_n;
            if (run_n >= need)
                linestate <= raw;
        end
    end

    // ---------------- HostDisconnect ----------------
    wire disc_mode = host_mode && is_hs && (opmode == 2'b00);

    reg       win;                    // window open
    reg [5:0] tail;                   // cycles left after hs_tx_act fell
    reg       acc;                    // disc seen in the open window
    reg       res;                    // result of the last closed window
    reg       done;                   // res not yet taken over

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            win  <= 1'b0;
            tail <= 6'd0;
            acc  <= 1'b0;
            res  <= 1'b0;
            done <= 1'b0;
        end else if (!disc_mode) begin
            win  <= 1'b0;
            acc  <= 1'b0;
            done <= 1'b0;
        end else begin
            if (ce60 && done)                  // taken over by host_disc below
                done <= 1'b0;
            if (hs_tx_act) begin
                acc  <= win ? (acc | disc_s) : disc_s;   // a new window starts clean
                win  <= 1'b1;
                tail <= DISC_TAIL;
            end else if (win) begin
                if (tail <= 6'd1) begin
                    win  <= 1'b0;
                    res  <= acc | disc_s;
                    done <= 1'b1;
                end else
                    acc <= acc | disc_s;
                tail <= tail - 6'd1;
            end
        end
    end

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n)
            host_disc <= 1'b0;
        else if (ce60) begin
            if (!disc_mode)  host_disc <= 1'b0;
            else if (done)   host_disc <= res;
        end
    end

endmodule
