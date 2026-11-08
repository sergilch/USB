//-----------------------------------------------------------------------------
// usb_bit_stuffer.v
//
// "Bit Stuffer" of the USB 2.0 PHY TX path (HS / FS / LS).  Position:
//
//   TX Holding -> SYNC/PID mux -> [THIS BLOCK] -> NRZI Encoder -> Serializer
//
// Rule (USB 2.0, 7.1.9): after six consecutive 1 bits a 0 is inserted.
//   * The stream starts with the SYNC pattern; its trailing 1 counts as the
//     first one of a run (the counter starts at 0 at every packet start and
//     SYNC simply passes through this block as ordinary data bytes).
//   * The stuffed 0 is inserted immediately after the sixth 1, so it is also
//     emitted when those six ones are the last bits of the packet (the spec
//     requires a stuff bit even right before EOP).
//
// Interface
//   Input : byte stream, ready/valid, in_last marks the last byte of a packet.
//   Output: words of the stuffed bit stream for the Serializer, ready/valid.
//           All words carry 8 valid bits (LSB first) except the last one
//           (out_last = 1), which carries out_nbits = 1..8 bits.  This is
//           exactly the input format of usb_tx_serializer (in_nbits / in_last),
//           the NRZI encoder in between only has to pass nbits / last through.
//   stuff_dis: 1 = pass bits unmodified (OpMode "disable bit stuffing and
//           NRZI", chirp / test modes).  Must be static during a packet.
//
// Clocking: one clock `clk` with a clock enable `ce`; all state changes and
//   all handshakes happen only on edges with ce = 1.
//     * clk60 domain       : clk = clk60,    ce = 1'b1
//     * clk_bit domain     : clk = clk_bit,  ce = ce60 (same strobe that
//       drives usb_tx_serializer, so out_ready = serializer in_ready).
//
// Implementation: every input byte expands combinationally to 8..10 bits
//   (worst case: two stuffs in one byte) which are appended to a 25-bit
//   accumulator; the accumulator is drained 8 bits per transfer.  A new byte
//   is accepted while at most 15 bits are buffered (15 + 10 = 25), so in_ready
//   depends on registers only (no combinational path from out_ready).
//   The threshold of 15 also guarantees that the output never runs dry while
//   input is available: an accepted byte adds >= 8 bits, and when no byte is
//   accepted the buffer holds >= 16 bits, so after draining 8 at least 8 bits
//   remain.  This is required for the gapless HS serializer behind this block.
//   Without stuffing the block sustains one byte per ce cycle; every stuffed
//   bit costs at most one stalled input cycle (NXT low in ULPI terms).
//
// Not covered: EOP-only packets (e.g. LS keep-alive) do not go through this
//   block - they have no data bits.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_bit_stuffer (
    input  wire        clk,
    input  wire        rst_n,        // async assert, sync release
    input  wire        ce,           // clock enable (tie to 1 on clk60)

    input  wire        stuff_dis,    // 1 = no bit stuffing

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0]  in_data,      // byte, bit 0 is sent first
    input  wire        in_last,      // last byte of the packet

    output wire        out_valid,
    input  wire        out_ready,
    output wire [7:0]  out_data,     // stuffed bits, LSB first
    output wire [3:0]  out_nbits,    // 8, or 1..8 on the last word
    output wire        out_last
);

    reg [24:0] acc;          // bit accumulator, bit 0 = next bit to send
    reg [4:0]  acc_cnt;      // valid bits in acc (0..25); bits above are 0
    reg [2:0]  ones;         // consecutive ones so far (0..5)
    reg        last_pend;    // last byte absorbed, flushing the accumulator

    // ---------------- byte expansion ----------------
    // returns {c_next[2:0], n[3:0], bits[9:0]}
    function [16:0] expand;
        input [2:0] c_in;
        input [7:0] d;
        input       dis;
        integer     i;
        reg [2:0]   c;
        reg [3:0]   n;
        reg [9:0]   b;
        begin
            c = c_in;
            n = 4'd0;
            b = 10'd0;
            if (dis) begin
                b = {2'b00, d};
                n = 4'd8;
                c = 3'd0;
            end else begin
                for (i = 0; i < 8; i = i + 1) begin
                    b[n] = d[i];
                    n    = n + 4'd1;
                    if (d[i]) begin
                        if (c == 3'd5) begin          // sixth one: stuff a 0
                            b[n] = 1'b0;
                            n    = n + 4'd1;
                            c    = 3'd0;
                        end else begin
                            c = c + 3'd1;
                        end
                    end else begin
                        c = 3'd0;
                    end
                end
            end
            expand = {c, n, b};
        end
    endfunction

    wire [16:0] ex      = expand(ones, in_data, stuff_dis);
    wire [9:0]  ex_bits = ex[9:0];
    wire [3:0]  ex_n    = ex[13:10];
    wire [2:0]  ex_c    = ex[16:14];

    // ---------------- handshakes ----------------
    assign in_ready  = (acc_cnt <= 5'd15) && !last_pend;
    wire   absorb    = ce && in_valid && in_ready;

    assign out_valid = (acc_cnt >= 5'd8) || last_pend;
    assign out_last  = last_pend && (acc_cnt <= 5'd8);
    assign out_nbits = (last_pend && (acc_cnt < 5'd8)) ? acc_cnt[3:0] : 4'd8;
    assign out_data  = acc[7:0];
    wire   emit      = ce && out_valid && out_ready;

    // ---------------- next-state logic ----------------
    reg [24:0] acc_n;
    reg [4:0]  cnt_n;

    always @* begin
        acc_n = acc;
        cnt_n = acc_cnt;
        if (emit) begin
            acc_n = acc >> 8;
            cnt_n = out_last ? 5'd0 : (acc_cnt - 5'd8);
        end
        if (absorb) begin
            acc_n = acc_n | ({15'd0, ex_bits} << cnt_n);
            cnt_n = cnt_n + {1'b0, ex_n};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= 25'd0;
            acc_cnt   <= 5'd0;
            ones      <= 3'd0;
            last_pend <= 1'b0;
        end else begin
            acc     <= acc_n;
            acc_cnt <= cnt_n;
            if (absorb) begin
                ones <= in_last ? 3'd0 : ex_c;      // counter restarts per packet
                if (in_last)
                    last_pend <= 1'b1;
            end
            if (emit && out_last)
                last_pend <= 1'b0;
        end
    end

endmodule
