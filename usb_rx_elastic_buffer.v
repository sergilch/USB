//-----------------------------------------------------------------------------
// usb_rx_elastic_buffer.v
//
// "Elastic Buffer (CDC)" of the USB 2.0 PHY RX path.  Position:
//
//   ... -> EOP / RxError check -> [THIS BLOCK] -> RX output stage (clk_bit, ce60)
//
// A FIFO of packet events (usb_rx_eop_check event words) from the write clock
// to the read clock.  In HS the write clock is the clock recovered by the CDR
// (the far transmitter's bit clock, up to +-1000 ppm away from the local PLL);
// the read side runs on clk_bit and takes at most one word per ce60 tick.  The
// writer produces at most one word per 7 recovered bits, i.e. about one word
// per tick, so the occupancy stays small (a few words of synchronizer latency
// plus the ppm drift over one packet); DEPTH = 16 leaves a wide margin.  The
// buffer does not need to be pre-filled: the ULPI RX Data Handler behind it
// accepts bytes at any rate.
//
// ASYNC = 1: write and read clocks are unrelated.  Gray-coded pointers, 2-FF
//   synchronizers in both directions.  The flags are conservative: w_full /
//   w_afull may stay set a few write clocks after a read, r_valid may rise a
//   few read clocks after a write.
// ASYNC = 0: both sides on the same clock (used for FS / LS, where the bit
//   chain already runs on clk_bit); the pointers are compared directly.
//
// Write side (wclk): w_en writes w_data when w_full = 0 (a write while full is
//   dropped and pulses w_ovf).  w_full / w_afull are registered:
//     w_full  = no free entry, w_afull = fewer than 2 free entries.
// Read side (rclk): r_valid / r_data show the oldest word (r_data is read
//   asynchronously from the memory); r_pop removes it (ignored when r_valid = 0).
//
// Reset: wrst_n / rrst_n, active low, asynchronous assert, release synchronous
//   to the respective clock.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_elastic_buffer #(
    parameter W     = 10,             // word width
    parameter AW    = 4,              // address width, DEPTH = 2**AW (>= 2)
    parameter ASYNC = 1
) (
    // write side
    input  wire          wclk,
    input  wire          wrst_n,
    input  wire          w_en,
    input  wire [W-1:0]  w_data,
    output reg           w_full,
    output reg           w_afull,
    output reg           w_ovf,

    // read side
    input  wire          rclk,
    input  wire          rrst_n,
    output wire          r_valid,
    output wire [W-1:0]  r_data,
    input  wire          r_pop
);

    localparam DEPTH = 1 << AW;

    function [AW:0] bin2gray;
        input [AW:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i + 1] ^ g[i];
        end
    endfunction

    reg [W-1:0] mem [0:DEPTH-1];

    // ---------------- write side ----------------
    reg  [AW:0] wbin, wgray;
    wire [AW:0] rgray_w;              // read pointer seen in the write domain
    wire        do_wr  = w_en && !w_full;
    wire [AW:0] wbin_n = wbin + (do_wr ? 1'b1 : 1'b0);
    wire [AW:0] wcnt_n = wbin_n - gray2bin(rgray_w);

    always @(posedge wclk) begin
        if (do_wr) mem[wbin[AW-1:0]] <= w_data;
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin    <= {(AW+1){1'b0}};
            wgray   <= {(AW+1){1'b0}};
            w_full  <= 1'b0;
            w_afull <= 1'b0;
            w_ovf   <= 1'b0;
        end else begin
            wbin    <= wbin_n;
            wgray   <= bin2gray(wbin_n);
            w_full  <= (wcnt_n >= DEPTH);
            w_afull <= (wcnt_n >= DEPTH - 1);
            w_ovf   <= w_en && w_full;
        end
    end

    // ---------------- read side ----------------
    reg  [AW:0] rbin, rgray;
    wire [AW:0] wgray_r;              // write pointer seen in the read domain

    assign r_valid = (rgray != wgray_r);
    assign r_data  = mem[rbin[AW-1:0]];

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else if (r_pop && r_valid) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end

    // ---------------- pointer crossing ----------------
    generate
        if (ASYNC != 0) begin : g_async
            reg [AW:0] rg_w1, rg_w2;  // read pointer -> write clock
            reg [AW:0] wg_r1, wg_r2;  // write pointer -> read clock
            always @(posedge wclk or negedge wrst_n) begin
                if (!wrst_n) begin
                    rg_w1 <= {(AW+1){1'b0}};
                    rg_w2 <= {(AW+1){1'b0}};
                end else begin
                    rg_w1 <= rgray;
                    rg_w2 <= rg_w1;
                end
            end
            always @(posedge rclk or negedge rrst_n) begin
                if (!rrst_n) begin
                    wg_r1 <= {(AW+1){1'b0}};
                    wg_r2 <= {(AW+1){1'b0}};
                end else begin
                    wg_r1 <= wgray;
                    wg_r2 <= wg_r1;
                end
            end
            assign rgray_w = rg_w2;
            assign wgray_r = wg_r2;
        end else begin : g_sync
            assign rgray_w = rgray;
            assign wgray_r = wgray;
        end
    endgenerate

endmodule
