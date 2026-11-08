//-----------------------------------------------------------------------------
// tb_usb_nrzi_encoder.v - self-checking testbench for usb_nrzi_encoder
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_nrzi usb_nrzi_encoder.v tb_usb_nrzi_encoder.v
//   vvp sim_nrzi
//
// A word source in the format of usb_bit_stuffer (8 bits per word, the last
// word of a packet 1..8 bits) with random gaps feeds the DUT; a sink with
// random back-pressure takes the output.  Checked:
//   * every transferred word with an independent NRZI decoder that runs on the
//     output bits only: bit = 1 if the level did not change, 0 if it changed,
//     starting from J (= 1) at every packet; only the valid bits are compared;
//   * bypass_en: output bits = input bits;
//   * directed patterns (valid bits only): HS SYNC 00 00 00 80 -> AA AA AA 2A,
//     FS SYNC 80 -> 2A (KJKJ...KK, J = 1), then PID D2h -> 1Bh (starts from K);
//   * pass-through: out_valid = in_valid, in_ready = out_ready, out_nbits and
//     out_last unchanged, in every cycle;
//   * ce: the line level only advances on ce ticks (valid / ready are held
//     high between ticks, so a level update on a non-ce edge corrupts the data).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_nrzi_encoder;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg       rst_n;
    reg [2:0] ce_cnt;
    wire      ce = (ce_cnt == 3'd7);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ce_cnt <= 3'd0;
        else        ce_cnt <= ce_cnt + 3'd1;
    end

    // ---------------- DUT ----------------
    reg        bypass_en = 1'b0;
    reg        in_valid  = 1'b0;
    reg  [7:0] in_data   = 8'd0;
    reg  [3:0] in_nbits  = 4'd8;
    reg        in_last   = 1'b0;
    wire       in_ready;
    wire       out_valid, out_last;
    wire [7:0] out_data;
    wire [3:0] out_nbits;
    reg        out_ready = 1'b1;

    usb_nrzi_encoder dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .bypass_en (bypass_en),
        .in_valid  (in_valid),
        .in_ready  (in_ready),
        .in_data   (in_data),
        .in_nbits  (in_nbits),
        .in_last   (in_last),
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (out_data),
        .out_nbits (out_nbits),
        .out_last  (out_last)
    );

    integer errors = 0;
    integer seed   = 32'h3C3C_A5A5;

    // ---------------- word list ----------------
    reg [7:0] w_data  [0:16383];
    reg [3:0] w_nbits [0:16383];
    reg       w_last  [0:16383];
    reg       w_byp   [0:16383];
    reg [7:0] w_exp   [0:16383];             // directed words: expected output
    reg       w_chk   [0:16383];             // 1 = compare with w_exp too
    integer   w_tail = 0;
    integer   w_head = 0;                    // next word to transfer

    task queue_word(input [7:0] d, input [3:0] nb, input last, input byp);
        begin
            w_data[w_tail]  = d;
            w_nbits[w_tail] = last ? nb : 4'd8;
            w_last[w_tail]  = last;
            w_byp[w_tail]   = byp;
            w_chk[w_tail]   = 1'b0;
            w_tail = w_tail + 1;
        end
    endtask

    task queue_exp(input [7:0] d, input [3:0] nb, input last, input [7:0] e);
        begin
            queue_word(d, nb, last, 1'b0);
            w_exp[w_tail - 1] = e;
            w_chk[w_tail - 1] = 1'b1;
        end
    endtask

    task queue_packet(input integer nw, input byp);
        integer i;
        reg [31:0] r;
        reg [7:0]  d;
        begin
            for (i = 0; i < nw; i = i + 1) begin
                r = $random(seed);
                case (r[10:8])                    // runs of ones / zeros, and random
                    3'd0:    d = 8'hFF;
                    3'd1:    d = 8'h00;
                    default: d = r[7:0];
                endcase
                queue_word(d, 4'd1 + ({$random(seed)} % 8), i == nw - 1, byp);
            end
        end
    endtask

    // ---------------- source / sink / checker ----------------
    reg       src_gaps   = 1'b1;
    reg       sink_stall = 1'b1;
    reg       dec_lvl    = 1'b1;             // decoder: level before the next bit (J at start)
    integer   words_ok   = 0;

    task check_word;
        integer i, n;
        reg     l, bit_in, bit_dec;
        reg [7:0] d;
        begin
            d = w_data[w_head];
            n = w_nbits[w_head];
            if ((out_nbits !== in_nbits) || (out_last !== in_last)) begin
                errors = errors + 1;
                $display("ERROR @%0t: nbits / last not passed through", $time);
            end
            if (w_chk[w_head] && (((out_data ^ w_exp[w_head]) & (8'hFF >> (8 - n))) !== 8'h00)) begin
                errors = errors + 1;
                $display("ERROR @%0t: word %0d: %02h -> %02h, expected %02h",
                         $time, w_head, d, out_data, w_exp[w_head]);
            end
            l = dec_lvl;
            for (i = 0; i < n; i = i + 1) begin
                bit_in = d[i];
                if (w_byp[w_head]) bit_dec = out_data[i];
                else               bit_dec = (out_data[i] === l);
                if (bit_dec !== bit_in) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: word %0d bit %0d: in %b, out level %b after %b (bypass %b)",
                             $time, w_head, i, bit_in, out_data[i], l, w_byp[w_head]);
                    i = n;
                end
                l = out_data[i];
            end
            dec_lvl = w_last[w_head] ? 1'b1 : l;      // every packet starts at J
            words_ok = words_ok + 1;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            // pure pass-through, every cycle
            if ((out_valid !== in_valid) || (in_ready !== out_ready) ||
                (out_nbits !== in_nbits) || (out_last !== in_last)) begin
                errors = errors + 1;
                $display("ERROR @%0t: handshake / nbits / last not passed through", $time);
            end
            if (bypass_en && (out_data !== in_data)) begin
                errors = errors + 1;
                $display("ERROR @%0t: bypass: out_data %02h != in_data %02h", $time, out_data, in_data);
            end

            if (ce) begin
                if (in_valid && out_ready) begin
                    check_word;
                    w_head = w_head + 1;
                end
                // present the next word (or hold the current one)
                if (!(in_valid && !out_ready)) begin
                    if ((w_head < w_tail) && !(src_gaps && ({$random(seed)} % 4 == 0))) begin
                        in_valid  <= 1'b1;
                        in_data   <= w_data[w_head];
                        in_nbits  <= w_nbits[w_head];
                        in_last   <= w_last[w_head];
                        bypass_en <= w_byp[w_head];
                    end else begin
                        in_valid  <= 1'b0;
                        in_data   <= $random(seed);       // garbage while not valid
                    end
                end
                out_ready <= sink_stall ? ({$random(seed)} % 3 != 0) : 1'b1;
            end
        end
    end

    task finish_all;
        begin
            while (w_head != w_tail) @(posedge clk);
            repeat (20) @(posedge clk);
        end
    endtask

    // ---------------- stimulus ----------------
    integer p;

    initial begin
        $dumpfile("tb_usb_nrzi_encoder.vcd");
        $dumpvars(0, tb_usb_nrzi_encoder);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (10) @(posedge clk);

        $display("Directed SYNC patterns");
        src_gaps = 1'b0; sink_stall = 1'b0;
        queue_exp(8'h00, 4'd8, 1'b0, 8'hAA);          // HS SYNC
        queue_exp(8'h00, 4'd8, 1'b0, 8'hAA);
        queue_exp(8'h00, 4'd8, 1'b0, 8'hAA);
        queue_exp(8'h80, 4'd8, 1'b1, 8'h2A);
        queue_exp(8'h80, 4'd8, 1'b0, 8'h2A);          // FS SYNC + ACK PID (D2h)
        queue_exp(8'hD2, 4'd8, 1'b1, 8'h1B);          // starts from K (end of SYNC)
        queue_exp(8'hFF, 4'd3, 1'b1, 8'hFF);          // short last word, all ones: stays J
        queue_exp(8'h00, 4'd1, 1'b1, 8'h00);          // one 0 bit from J: K (only valid bits compared)
        finish_all;

        $display("Random packets, gaps and back-pressure");
        src_gaps = 1'b1; sink_stall = 1'b1;
        for (p = 0; p < 600; p = p + 1)
            queue_packet(1 + ({$random(seed)} % 12), ({$random(seed)} % 5) == 0);
        finish_all;

        $display("Random packets, full rate");
        src_gaps = 1'b0; sink_stall = 1'b0;
        for (p = 0; p < 300; p = p + 1)
            queue_packet(1 + ({$random(seed)} % 12), ({$random(seed)} % 5) == 0);
        finish_all;

        repeat (20) @(posedge clk);
        $display("%0d words checked", words_ok);
        if (words_ok != w_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d words queued, %0d checked", w_tail, words_ok);
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #50_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
