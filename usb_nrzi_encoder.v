//-----------------------------------------------------------------------------
// usb_nrzi_encoder.v
//
// "NRZI Encoder" of the USB 2.0 PHY TX path (HS / FS / LS).  Position:
//
//   TX Holding -> SYNC/PID mux -> Bit Stuffer -> [THIS BLOCK] -> Serializer
//
// Rule (USB 2.0, 7.1.8): a 0 data bit is sent as a change of the line level, a
//   1 as no change.  Line level J = 1, K = 0.  Every packet starts from the
//   idle level J, so the first 0 of SYNC goes out as K.
//
// Interface: the word format of usb_bit_stuffer (output) and usb_tx_serializer
//   (input).  Bits are LSB first; every word carries 8 valid bits except the
//   last word of the packet (in_last = 1), which carries in_nbits = 1..8 bits.
//   in_nbits / in_last are passed through unchanged; bits above in_nbits in
//   the last word are don't care (the serializer ignores them).
//
//   The block is a combinational pass-through in the handshake:
//     out_valid = in_valid, in_ready = out_ready, out_data = NRZI(in_data).
//   The only state is the line level after the last transferred bit (lvl).  It
//   advances on every transfer (ce && in_valid && out_ready) and returns to J
//   after the last word of a packet.  There is no combinational path from
//   out_ready to out_valid.
//
// bypass_en: 1 = no NRZI, data bits are line levels (OpMode "disable bit
//   stuffing and NRZI": chirp, test patterns).  Must be static during a packet.
//   lvl is still reset to J after each last word.
//
// Clocking: one clock `clk` with a clock enable `ce` (clk_bit with ce = ce60 in
//   the PHY).  out_data is an 8-cycle multicycle path in that case.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_nrzi_encoder (
    input  wire        clk,
    input  wire        rst_n,        // async assert, sync release
    input  wire        ce,           // clock enable (tick)

    input  wire        bypass_en,    // 1 = no NRZI

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0]  in_data,      // data bits, LSB first
    input  wire [3:0]  in_nbits,     // valid bits of the last word (1..8)
    input  wire        in_last,

    output wire        out_valid,
    input  wire        out_ready,
    output wire [7:0]  out_data,     // line levels (J = 1, K = 0), LSB first
    output wire [3:0]  out_nbits,
    output wire        out_last
);

    reg lvl;                         // line level after the last sent bit

    // level after each bit: l[i] = d[i] ? l[i-1] : ~l[i-1]  =>  l[i] = l[i-1] ^ ~d[i]
    function [7:0] nrzi;
        input       l0;
        input [7:0] d;
        integer     i;
        reg         l;
        begin
            l = l0;
            for (i = 0; i < 8; i = i + 1) begin
                l       = l ^ ~d[i];
                nrzi[i] = l;
            end
        end
    endfunction

    wire [7:0] enc = nrzi(lvl, in_data);

    assign out_valid = in_valid;
    assign in_ready  = out_ready;
    assign out_data  = bypass_en ? in_data : enc;
    assign out_nbits = in_nbits;
    assign out_last  = in_last;

    wire xfer = ce && in_valid && out_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lvl <= 1'b1;                       // J
        else if (xfer)
            lvl <= in_last ? 1'b1 : enc[7];    // full word: level after bit 7
    end

endmodule
