//-----------------------------------------------------------------------------
// usb_rx_nrzi_decoder.v
//
// "NRZI Decoder" of the USB 2.0 PHY RX path (HS / FS / LS).  Position:
//
//   RX front end -> [THIS BLOCK] -> SYNC detect -> Bit Unstuffer -> Deserializer
//                                                               -> EOP / RxError check
//
// Bit-serial stream interface (used by every stage of the RX bit chain)
//   i_en  : bit strobe.  One received bit per cycle with i_en = 1 (HS: every
//           cycle of the recovered clock; FS / LS: the DPLL strobe on clk_bit).
//           All other inputs are only looked at when i_en = 1.
//   i_lvl : line level of the bit, J = 1 / K = 0.
//   i_se0 : the bit is an SE0 (FS / LS only; tied 0 in HS).
//   i_act : the receiver is active (HS: no squelch, CDR locked, RX enabled;
//           FS / LS: RX enabled).  Bits with i_act = 0 are not data.
//
// Rule (USB 2.0, 7.1.8): a change of level is a 0, no change is a 1.  The
//   reference level returns to J (idle) after an SE0 bit and while the receiver
//   is inactive, so the first K of a SYNC pattern decodes as 0.
//
// Output: the same stream one cycle later (registered), with o_bit = decoded
//   data bit; o_se0 / o_act are passed through.  o_en = i_en delayed.
//
// Clocking: one clock `clk` (recovered HS clock, or clk_bit for FS / LS),
//   active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_nrzi_decoder (
    input  wire clk,
    input  wire rst_n,

    input  wire i_en,
    input  wire i_lvl,
    input  wire i_se0,
    input  wire i_act,

    output reg  o_en,
    output reg  o_bit,
    output reg  o_se0,
    output reg  o_act
);

    reg prev;                         // level of the previous bit (J after idle / SE0)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev  <= 1'b1;
            o_en  <= 1'b0;
            o_bit <= 1'b1;
            o_se0 <= 1'b0;
            o_act <= 1'b0;
        end else begin
            o_en <= i_en;
            if (i_en) begin
                o_bit <= (i_lvl == prev);
                o_se0 <= i_se0;
                o_act <= i_act;
                prev  <= (!i_act || i_se0) ? 1'b1 : i_lvl;
            end
        end
    end

endmodule
