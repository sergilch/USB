//-----------------------------------------------------------------------------
// tb_usb_rx_status_sync.v - unit testbench for usb_rx_status_sync
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rx_status_sync usb_rx_status_flt.v \
//            usb_rx_status_sync.v tb_usb_rx_status_sync.v
//   vvp sim_rx_status_sync
//
// Stimulus: the asynchronous inputs change on the falling clk_bit edge (so the
// sampling edge is unambiguous), with random run lengths from 1 cycle up to a
// few filter lengths: pulses shorter than, equal to and longer than the filter.
//
// Reference (history-based, independent of the counter in the DUT): let in[k]
// be an input as sampled at rising edge k (the first flop; its reset value
// counts as an input of ISO).
//   * rxdp / rxdm / rxrcv: out after edge t = in[t-1].
//   * squelch / disc (filter length L, clk_bit): out after edge t flips to
//     !out iff in[t-2-L .. t-2] all equal !out (the filter sees the second
//     flop, L + 1 samples).
//   * VBUS / ID (filter length L, ce60 ticks): as above over in[e-2] for the
//     last L + 1 edges e with ce60 high, and the output may change on those
//     edges only.
// Every output is compared after every rising edge, also in and right after
// reset (reset values = isolated values: rxdp = rxdm = 0, rxrcv = 1,
// squelch = 1, disc = 0, a_vbus_vld = sess_vld = 0, sess_end = 1, id_gnd = 0).
// Phases: filter lengths (sq, disc, vb) = (0, 0, 0), (2, 5, 1), (7, 1, 3),
// (15, 15, 0); a long VBUS debounce (vb_flt = 200 ticks) with bounce; reset in
// the middle of activity.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_status_sync;
    parameter real HALF = 1.0416667;

    integer errors = 0;
    integer seed   = 32'h51A7_0C11;

    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;
    reg rst_n = 1'b0;
    reg [2:0] ce_cnt = 3'd0;
    wire ce60 = (ce_cnt == 3'd7);
    always @(posedge clk_bit) ce_cnt <= ce_cnt + 3'd1;

    // inputs: bit order {id, sess_end, sess_vld, a_vbus, disc, squelch, rxrcv, rxdm, rxdp}
    localparam [8:0] ISO = {1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0};
    reg  [8:0] in = ISO;
    reg  [3:0] sq_flt = 4'd0, disc_flt = 4'd0;
    reg [15:0] vb_flt = 16'd0;
    wire [8:0] out;

    usb_rx_status_sync dut (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60),
        .rxdp(in[0]), .rxdm(in[1]), .rxrcv(in[2]), .squelch(in[3]), .disc(in[4]),
        .a_vbus_vld(in[5]), .sess_vld(in[6]), .sess_end(in[7]), .id_gnd(in[8]),
        .sq_flt(sq_flt), .disc_flt(disc_flt), .vb_flt(vb_flt),
        .rxdp_s(out[0]), .rxdm_s(out[1]), .rxrcv_s(out[2]), .squelch_s(out[3]),
        .disc_s(out[4]), .a_vbus_vld_s(out[5]), .sess_vld_s(out[6]),
        .sess_end_s(out[7]), .id_gnd_s(out[8]));

    initial begin
        $dumpfile("tb_usb_rx_status_sync.vcd");
        $dumpvars(0, tb_usb_rx_status_sync);
    end

    // ---------------- reference ----------------
    // hist[b][k]: input bit b sampled at edge (cyc - k), k = 0 newest
    localparam HN = 300;
    reg  [HN-1:0] hist [0:8];        // clk_bit history
    reg  [HN-1:0] vhist [5:8];       // per ce60 tick: input sampled one edge before
    reg  [8:0] in_prev;               // what the first flop took at the previous edge
    reg  [8:0] exp_o;
    integer    cyc = 0, b, k, L;
    reg        ce_q = 1'b0;           // ce60 as seen by the DUT at the next edge
    always @(negedge clk_bit) ce_q <= (ce_cnt == 3'd7);
    reg        all;
    reg  [8:0] o_before;

    task ref_reset;
        begin
            for (b = 0; b < 9; b = b + 1) hist[b] = {HN{ISO[b]}};
            for (b = 5; b < 9; b = b + 1) vhist[b] = {HN{ISO[b]}};
            exp_o = ISO; in_prev = ISO;   // flops hold ISO: same as an ISO history
        end
    endtask

    initial ref_reset;

    always @(posedge clk_bit) begin
        #0.1;
        cyc = cyc + 1;
        if (!rst_n) begin
            ref_reset;
            if (out !== ISO) begin
                errors = errors + 1;
                $display("ERROR @%0t: reset value %b, expected %b", $time, out, ISO);
            end
        end else begin
            o_before = exp_o;
            // in_prev = input sampled at this edge's predecessor = in[t-1]
            for (b = 0; b < 9; b = b + 1) hist[b] = {hist[b][HN-2:0], in_prev[b]};
            // group 1: second flop = what the first took at the previous edge
            for (b = 0; b < 3; b = b + 1) exp_o[b] = hist[b][0];
            // group 2: the filter sees the second flop before this edge = hist[1]
            for (b = 3; b < 5; b = b + 1) begin
                L = (b == 3) ? sq_flt : disc_flt;
                all = 1;
                for (k = 1; k <= L + 1; k = k + 1)
                    if (hist[b][k] != !o_before[b]) all = 0;
                if (all) exp_o[b] = !o_before[b];
            end
            // group 3 (ce60 was high before this edge: the DUT enable at this edge)
            if (ce_q) begin
                for (b = 5; b < 9; b = b + 1) vhist[b] = {vhist[b][HN-2:0], hist[b][1]};
                for (b = 5; b < 9; b = b + 1) begin
                    L = vb_flt;
                    all = 1;
                    for (k = 0; k <= L; k = k + 1)
                        if (vhist[b][k] != !o_before[b]) all = 0;
                    if (all) exp_o[b] = !o_before[b];
                end
            end
            if (out !== exp_o) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("ERROR @%0t: out %b, expected %b (flt %0d/%0d/%0d)",
                             $time, out, exp_o, sq_flt, disc_flt, vb_flt);
                exp_o = out;          // resynchronize, report each divergence once
            end
            in_prev = in;
        end
    end

    // ---------------- stimulus ----------------
    integer run_left [0:8];
    integer maxrun   [0:8];
    integer ph;

    initial for (b = 0; b < 9; b = b + 1) run_left[b] = 1;

    always @(negedge clk_bit) begin : stim
        integer i;
        for (i = 0; i < 9; i = i + 1) begin
            run_left[i] = run_left[i] - 1;
            if (run_left[i] <= 0) begin
                in[i] = ~in[i];
                run_left[i] = 1 + ({$random(seed)} % maxrun[i]);
            end
        end
    end

    task set_phase(input integer s, input integer d, input integer v);
        integer i;
        begin
            sq_flt = s; disc_flt = d; vb_flt = v;
            for (i = 0; i < 3; i = i + 1) maxrun[i] = 6;
            maxrun[3] = 2 * s + 4;
            maxrun[4] = 2 * d + 4;
            for (i = 5; i < 9; i = i + 1) maxrun[i] = 8 * (2 * v + 3);
        end
    endtask

    // ---------------- sequence ----------------
    initial begin
        set_phase(0, 0, 0);
        repeat (7) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        ph = 0;
        repeat (3000) @(posedge clk_bit);
        // filter lengths change only while the inputs are quiet
        @(negedge clk_bit) rst_n = 1'b0;
        set_phase(2, 5, 1);
        repeat (4) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (6000) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b0;
        set_phase(7, 1, 3);
        repeat (3) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (8000) @(posedge clk_bit);
        // reset in the middle of activity, then the longest squelch filter
        @(negedge clk_bit) rst_n = 1'b0;
        set_phase(15, 15, 0);
        repeat (2) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (8000) @(posedge clk_bit);
        // long VBUS debounce: bouncing for a while (runs up to 120 ticks), then
        // a clean level (history depth limits L to HN - 1 = 299 ticks)
        @(negedge clk_bit) rst_n = 1'b0;
        set_phase(0, 0, 200);
        for (b = 5; b < 9; b = b + 1) maxrun[b] = 8 * 120;
        repeat (2) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (8 * 2000) @(posedge clk_bit);
        for (b = 5; b < 9; b = b + 1) begin maxrun[b] = 8 * 1000; run_left[b] = 8 * 1000; end
        repeat (8 * 900) @(posedge clk_bit);
        if (out[8:5] !== in[8:5]) begin
            errors = errors + 1;
            $display("ERROR: VBUS / ID outputs %b did not settle to %b after 900 ticks",
                     out[8:5], in[8:5]);
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
