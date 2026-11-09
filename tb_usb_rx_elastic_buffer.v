//-----------------------------------------------------------------------------
// tb_usb_rx_elastic_buffer.v - self-checking testbench for usb_rx_elastic_buffer
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxeb usb_rx_elastic_buffer.v tb_usb_rx_elastic_buffer.v
//   vvp sim_rxeb
//
// Two instances: ASYNC = 1 (8 words) between two unrelated clocks, ASYNC = 0
// (4 words) on one clock.  A writer pushes an incrementing sequence at random
// (normally only when w_full = 0, sometimes on purpose while full), a reader
// pops at random.  Clock ratios: about 1000 ppm apart, write 3x faster, write
// 3x slower.  Checked:
//   * the read sequence is the write sequence without the words that were
//     written while full (those pulse w_ovf);
//   * safety of the conservative flags against the true occupancy:
//       w_full = 0  -> at most DEPTH-1 words stored,
//       w_afull = 0 -> at most DEPTH-2 words stored,
//       r_valid = 1 -> at least one word stored;
//   * the flags recover: after the reader drains, w_full / w_afull fall and
//     r_valid falls; after a write, r_valid rises within a few read clocks.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_elastic_buffer;

    real wh = 1.0417, rh = 1.0427;            // half periods
    reg  wclk = 1'b0, rclk = 1'b0;
    initial forever #(wh) wclk = ~wclk;
    initial begin #0.3; forever #(rh) rclk = ~rclk; end
    reg  rst_n;

    integer errors = 0;
    integer seed   = 32'h0EB0_0EB0;

    // ---------------- async instance ----------------
    reg        a_wen = 1'b0;
    reg  [9:0] a_wd  = 10'd0;
    wire       a_full, a_afull, a_ovf, a_valid;
    wire [9:0] a_rd;
    reg        a_pop = 1'b0;

    usb_rx_elastic_buffer #(.W(10), .AW(3), .ASYNC(1)) dut_a (
        .wclk (wclk), .wrst_n (rst_n), .w_en (a_wen), .w_data (a_wd),
        .w_full (a_full), .w_afull (a_afull), .w_ovf (a_ovf),
        .rclk (rclk), .rrst_n (rst_n), .r_valid (a_valid), .r_data (a_rd), .r_pop (a_pop)
    );

    // ---------------- sync instance (both sides on wclk) ----------------
    reg        s_wen = 1'b0;
    reg  [9:0] s_wd  = 10'd0;
    wire       s_full, s_afull, s_ovf, s_valid;
    wire [9:0] s_rd;
    reg        s_pop = 1'b0;

    usb_rx_elastic_buffer #(.W(10), .AW(2), .ASYNC(0)) dut_s (
        .wclk (wclk), .wrst_n (rst_n), .w_en (s_wen), .w_data (s_wd),
        .w_full (s_full), .w_afull (s_afull), .w_ovf (s_ovf),
        .rclk (wclk), .rrst_n (rst_n), .r_valid (s_valid), .r_data (s_rd), .r_pop (s_pop)
    );

    // ---------------- scoreboards ----------------
    reg [9:0] a_q [0:65535];  integer a_wr = 0, a_rp = 0, a_lost = 0, a_ovfs = 0;
    reg [9:0] s_q [0:65535];  integer s_wr = 0, s_rp = 0, s_lost = 0, s_ovfs = 0;
    integer   a_seq = 0, s_seq = 0;

    reg wr_on = 1'b1, rd_on = 1'b1, force_full = 1'b0;
    integer wr_rate = 2, rd_rate = 2;          // 1 in N chance per cycle (lower = busier)

    // writers (wclk)
    always @(posedge wclk) begin
        if (rst_n) begin
            // flag safety (true occupancy = accepted writes - pops)
            if (!a_full  && (a_wr - a_rp) > 7) begin errors = errors + 1; $display("ERROR @%0t: async: w_full low with %0d words", $time, a_wr - a_rp); end
            if (!a_afull && (a_wr - a_rp) > 6) begin errors = errors + 1; $display("ERROR @%0t: async: w_afull low with %0d words", $time, a_wr - a_rp); end
            if (!s_full  && (s_wr - s_rp) > 3) begin errors = errors + 1; $display("ERROR @%0t: sync: w_full low with %0d words", $time, s_wr - s_rp); end
            if (!s_afull && (s_wr - s_rp) > 2) begin errors = errors + 1; $display("ERROR @%0t: sync: w_afull low with %0d words", $time, s_wr - s_rp); end
            if (a_ovf) a_ovfs = a_ovfs + 1;
            if (s_ovf) s_ovfs = s_ovfs + 1;

            // async writer: the DUT samples a_wen / a_wd at this edge
            if (a_wen) begin
                if (!a_full) begin a_q[a_wr % 65536] = a_wd; a_wr = a_wr + 1; end
                else         a_lost = a_lost + 1;
            end
            a_wen <= 1'b0;
            if (wr_on && ({$random(seed)} % wr_rate == 0) && (force_full || !a_full)) begin
                a_wen <= 1'b1;
                a_wd  <= a_seq;
                a_seq = a_seq + 1;
            end

            // sync writer / reader
            // (checked before this edge's write / pop is counted)
            if (s_valid && (s_wr - s_rp) < 1) begin
                errors = errors + 1;
                $display("ERROR @%0t: sync: r_valid with no word stored", $time);
            end
            if (s_wen) begin
                if (!s_full) begin s_q[s_wr % 65536] = s_wd; s_wr = s_wr + 1; end
                else         s_lost = s_lost + 1;
            end
            if (s_pop && s_valid) begin
                if (s_rp >= s_wr || s_rd !== s_q[s_rp % 65536]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: sync read %0d, expected %0d", $time, s_rd, s_q[s_rp % 65536]);
                end
                s_rp = s_rp + 1;
            end
            s_wen <= 1'b0;
            if (wr_on && ({$random(seed)} % wr_rate == 0) && (force_full || !s_full)) begin
                s_wen <= 1'b1;
                s_wd  <= s_seq;
                s_seq = s_seq + 1;
            end
            s_pop <= rd_on && ({$random(seed)} % rd_rate == 0);
        end
    end

    // async reader (rclk)
    always @(posedge rclk) begin
        if (rst_n) begin
            if (a_valid && (a_wr - a_rp) < 1) begin
                errors = errors + 1;
                $display("ERROR @%0t: async: r_valid with no word stored", $time);
            end
            if (a_pop && a_valid) begin
                if (a_rp >= a_wr || a_rd !== a_q[a_rp % 65536]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: async read %0d, expected %0d", $time, a_rd, a_q[a_rp % 65536]);
                end
                a_rp = a_rp + 1;
            end
            a_pop <= rd_on && ({$random(seed)} % rd_rate == 0);
        end
    end

    task phase(input real w, input real r, input integer wrate, input integer rrate, input integer cycles);
        begin
            wh = w; rh = r; wr_rate = wrate; rd_rate = rrate;
            wr_on = 1'b1; rd_on = 1'b1;
            repeat (cycles) @(posedge wclk);
        end
    endtask

    task drain_check;
        begin
            wr_on = 1'b0; force_full = 1'b0; rd_on = 1'b1; rd_rate = 1;
            repeat (60) @(posedge wclk);
            repeat (20) @(posedge rclk);
            if (a_full || a_afull || a_valid || s_full || s_afull || s_valid) begin
                errors = errors + 1;
                $display("ERROR @%0t: flags did not recover (async full %b afull %b valid %b, sync %b %b %b)",
                         $time, a_full, a_afull, a_valid, s_full, s_afull, s_valid);
            end
            if (a_rp != a_wr || s_rp != s_wr) begin
                errors = errors + 1;
                $display("ERROR @%0t: words left: async %0d, sync %0d", $time, a_wr - a_rp, s_wr - s_rp);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_usb_rx_elastic_buffer.vcd");
        $dumpvars(0, tb_usb_rx_elastic_buffer);
        rst_n = 1'b0;
        repeat (5) @(posedge wclk);
        #0.5 rst_n = 1'b1;

        $display("~1000 ppm apart, balanced");
        phase(1.0417, 1.0427, 2, 2, 20000);
        drain_check;
        $display("Write side 3x faster (buffer runs full)");
        phase(1.0, 3.0, 1, 1, 20000);
        drain_check;
        $display("Write side 3x slower");
        phase(3.0, 1.0, 1, 2, 20000);
        drain_check;
        $display("One word at a time: r_valid latency");
        wh = 1.0417; rh = 1.3;
        rd_on = 1'b0;
        repeat (20) begin
            @(posedge wclk); #0.1;
            a_wen = 1'b1; a_wd = a_seq; a_seq = a_seq + 1;
            s_wen = 1'b1; s_wd = s_seq; s_seq = s_seq + 1;
            @(posedge wclk); #0.1; a_wen = 1'b0; s_wen = 1'b0;
            repeat (8) @(posedge rclk);
            if (!a_valid) begin errors = errors + 1; $display("ERROR @%0t: r_valid not up 8 read clocks after a write", $time); end
        end
        drain_check;
        $display("Writes while full are dropped (w_ovf)");
        rd_on = 1'b0; wr_on = 1'b1; force_full = 1'b1; wr_rate = 1;
        repeat (100) @(posedge wclk);
        drain_check;
        if (a_lost == 0 || s_lost == 0 || a_ovfs != a_lost || s_ovfs != s_lost) begin
            errors = errors + 1;
            $display("ERROR: overflow: async lost %0d ovf %0d, sync lost %0d ovf %0d", a_lost, a_ovfs, s_lost, s_ovfs);
        end

        $display("async: %0d words, sync: %0d words; dropped %0d / %0d", a_rp, s_rp, a_lost, s_lost);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
