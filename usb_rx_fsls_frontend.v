//-----------------------------------------------------------------------------
// usb_rx_fsls_frontend.v
//
// FS / LS part of the RX front end of the USB 2.0 PHY: receiver status sync
// and digital clock / data recovery (DPLL).  Position:
//
//   AFE: FS/LS differential + single-ended receivers --rxrcv, rxdp, rxdm-->
//        [THIS BLOCK] --> FS/LS RX bit chain (usb_rx_decoder, FS/LS)
//
// Assumption (work plan, decision D2): FS / LS data is not recovered by the HS
// CDR.  The receiver outputs are oversampled on clk_bit (480 MHz): FS_DIV = 40
// samples per FS bit, LS_DIV = 320 per LS bit.
//
// Inputs (asynchronous, from the AFE)
//   rxrcv : differential receiver, 1 = D+ above D-
//   rxdp, rxdm : single-ended receivers of D+ and D-
//   SE0 = both single-ended receivers low.  J / K: FS J = D+ high (rxrcv = 1),
//   LS J = D- high (rxrcv = 0); `ls` selects the polarity and the bit rate.
//   enable : 1 = FS / LS reception allowed (clk_bit domain).
//
// What it does
//   * 2-FF synchronizers for rxrcv, rxdp, rxdm;
//   * symbol = SE0, or J / K from rxrcv (rxrcv is ignored during SE0, where the
//     differential receiver output is undefined);
//   * DPLL: a bit-time counter is restarted at every symbol change and strobes
//     b_en half a bit time later, in the middle of the bit.  Without changes it
//     keeps strobing once per bit time.  Bit stuffing guarantees a change at
//     least every 7 bits, so the allowed clock tolerance (FS +-0.25 %, LS
//     +-1.5 %) moves the sample point by at most about a fifth of a bit.  SE0
//     glitches at J/K crossovers (D+/D- skew) are shorter than half a bit and
//     are never sampled; they only shift the phase by their own length;
//   * b_lvl / b_se0 = the symbol at the strobe, b_act = enable.
//
// Clocking: clk_bit, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_fsls_frontend #(
    parameter FS_DIV = 40,
    parameter LS_DIV = 320,
    parameter DIV_W  = 9
) (
    input  wire clk,
    input  wire rst_n,

    input  wire rxrcv,
    input  wire rxdp,
    input  wire rxdm,
    input  wire ls,                   // 1 = LS (polarity, bit rate), 0 = FS
    input  wire enable,

    output reg  b_en,
    output reg  b_lvl,
    output reg  b_se0,
    output reg  b_act
);

    reg rc1, rc2, dp1, dp2, dm1, dm2;
    reg se0_q, lvl_q;                 // symbol of the previous cycle
    reg [DIV_W-1:0] cnt;

    wire se0_s = !dp2 && !dm2;
    wire lvl_s = ls ? !rc2 : rc2;
    wire chg   = (se0_s != se0_q) || (!se0_s && (lvl_s != lvl_q));

    wire [DIV_W-1:0] div_m1 = ls ? (LS_DIV - 1) : (FS_DIV - 1);
    wire [DIV_W-1:0] half   = ls ? (LS_DIV / 2) : (FS_DIV / 2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rc1   <= 1'b0;  rc2 <= 1'b0;
            dp1   <= 1'b0;  dp2 <= 1'b0;
            dm1   <= 1'b0;  dm2 <= 1'b0;
            se0_q <= 1'b1;
            lvl_q <= 1'b1;
            cnt   <= {DIV_W{1'b0}};
            b_en  <= 1'b0;
            b_lvl <= 1'b1;
            b_se0 <= 1'b0;
            b_act <= 1'b0;
        end else begin
            rc1 <= rxrcv;  rc2 <= rc1;
            dp1 <= rxdp;   dp2 <= dp1;
            dm1 <= rxdm;   dm2 <= dm1;
            se0_q <= se0_s;
            lvl_q <= se0_s ? lvl_q : lvl_s;

            if (chg)                cnt <= {{(DIV_W-1){1'b0}}, 1'b1};
            else if (cnt >= div_m1) cnt <= {DIV_W{1'b0}};
            else                    cnt <= cnt + 1'b1;

            b_en <= 1'b0;
            if (!chg && (cnt == half)) begin
                b_en  <= 1'b1;
                b_lvl <= lvl_s;
                b_se0 <= se0_s;
                b_act <= enable;
            end
        end
    end

endmodule
