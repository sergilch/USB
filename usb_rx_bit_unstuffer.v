//-----------------------------------------------------------------------------
// usb_rx_bit_unstuffer.v
//
// "Bit Unstuffer" of the USB 2.0 PHY RX path (HS / FS / LS).  Position:
//
//   RX front end -> NRZI Decoder -> SYNC detect -> [THIS BLOCK] -> Deserializer
//                                                               -> EOP / RxError check
//
// Rule (USB 2.0, 7.1.9): the transmitter inserts a 0 after six consecutive 1s.
//   The receiver drops that 0; a 1 in its place is a bit-stuff violation.
//   * The run counter is loaded with 1 on the final 1 of SYNC (o_sync from
//     usb_rx_sync_detect), matching usb_bit_stuffer on the TX side, where SYNC
//     passes through the stuffer as ordinary data.
//   * Only bits inside a packet (i_pkt, i_act, no SE0) are processed; all other
//     bits clear the counter and are not data.
//   * After a violation the counter restarts at 0.
//   * HS: the EOP (01111111 before NRZI) always produces a violation: that is
//     how the EOP check recognises the HS EOP.  FS / LS: a violation is an
//     error (RxError).
//
// Interface: the stream of usb_rx_sync_detect, registered, with
//   o_dat  : this bit is a data bit (i.e. not SYNC, not a stuff bit, not a
//            violation, not SE0, inside a packet); o_bit is its value;
//   o_serr : this bit is a bit-stuff violation (a 1 after six 1s);
//   o_en, o_se0, o_act, o_sync, o_pkt passed through.
//
// Clocking: one clock `clk`, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_bit_unstuffer (
    input  wire clk,
    input  wire rst_n,

    input  wire i_en,
    input  wire i_bit,
    input  wire i_se0,
    input  wire i_act,
    input  wire i_sync,
    input  wire i_pkt,

    output reg  o_en,
    output reg  o_dat,
    output reg  o_bit,
    output reg  o_serr,
    output reg  o_se0,
    output reg  o_act,
    output reg  o_sync,
    output reg  o_pkt
);

    reg [2:0] ones;                   // consecutive ones (0..6)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ones   <= 3'd0;
            o_en   <= 1'b0;
            o_dat  <= 1'b0;
            o_bit  <= 1'b1;
            o_serr <= 1'b0;
            o_se0  <= 1'b0;
            o_act  <= 1'b0;
            o_sync <= 1'b0;
            o_pkt  <= 1'b0;
        end else begin
            o_en   <= i_en;
            o_dat  <= 1'b0;
            o_serr <= 1'b0;
            o_sync <= 1'b0;
            if (i_en) begin
                o_bit  <= i_bit;
                o_se0  <= i_se0;
                o_act  <= i_act;
                o_sync <= i_sync;
                o_pkt  <= i_pkt;
                if (i_sync) begin
                    ones <= 3'd1;                       // final 1 of SYNC
                end else if (i_pkt && i_act && !i_se0) begin
                    if (ones == 3'd6) begin
                        if (i_bit) o_serr <= 1'b1;      // violation
                        ones <= 3'd0;                   // stuffed 0 dropped
                    end else begin
                        o_dat <= 1'b1;
                        ones  <= i_bit ? ones + 3'd1 : 3'd0;
                    end
                end else begin
                    ones <= 3'd0;
                end
            end
        end
    end

endmodule
