//-----------------------------------------------------------------------------
// tb_usb_rx_sync_detect.v - self-checking testbench for usb_rx_sync_detect
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxsync usb_rx_sync_detect.v tb_usb_rx_sync_detect.v
//   vvp sim_rxsync
//
// Two instances (ZMIN = 6 for HS, ZMIN = 4 for FS/LS) get the same decoded bit
// stream: idle 1s, SYNC-like zero runs of random length (shorter and longer
// than ZMIN), packet bodies with long zero runs inside (must not trigger), SE0
// bits and receiver-inactive bits (rearm).  The expected result comes from an
// independent window model: a hit is a 1 whose preceding ZMIN bits since the
// last rearm were all 0, seen while hunting.  Checked per strobe:
//   * o_sync exactly on the expected bits, nowhere else;
//   * o_pkt = 1 exactly for the bits after a hit up to and including the bit
//     that rearms (SE0 / inactive);
//   * o_en / o_bit / o_se0 / o_act passed through with one cycle of latency;
//   * enough hits and near misses (ZMIN - 1 zeros) for both instances.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_sync_detect;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n;

    reg  i_en = 1'b0, i_bit = 1'b1, i_se0 = 1'b0, i_act = 1'b0;
    wire a_en, a_bit, a_se0, a_act, a_sync, a_pkt;
    wire b_en, b_bit, b_se0, b_act, b_sync, b_pkt;

    usb_rx_sync_detect #(.ZMIN(6)) dut_a (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_bit (i_bit), .i_se0 (i_se0), .i_act (i_act),
        .o_en (a_en), .o_bit (a_bit), .o_se0 (a_se0), .o_act (a_act),
        .o_sync (a_sync), .o_pkt (a_pkt)
    );

    usb_rx_sync_detect #(.ZMIN(4)) dut_b (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_bit (i_bit), .i_se0 (i_se0), .i_act (i_act),
        .o_en (b_en), .o_bit (b_bit), .o_se0 (b_se0), .o_act (b_act),
        .o_sync (b_sync), .o_pkt (b_pkt)
    );

    integer errors = 0;
    integer seed   = 32'h2468_ACE0;

    // ---------------- window reference model (one per ZMIN) ----------------
    reg [15:0] hist_a = 16'hFFFF, hist_b = 16'hFFFF;   // 1 = "not a zero since rearm"
    reg        hunt_a = 1'b1, hunt_b = 1'b1;
    integer    hits_a = 0, hits_b = 0, near_a = 0, near_b = 0;

    // expected outputs of the last strobe
    reg x_valid = 1'b0, x_bit, x_se0, x_act, xa_sync, xa_pkt, xb_sync, xb_pkt;
    reg y_bit, y_se0, y_act, ya_sync, ya_pkt, yb_sync, yb_pkt;   // staged for the next edge

    task model(input b, input se0, input act);
        begin
            ya_pkt = !hunt_a;
            yb_pkt = !hunt_b;
            ya_sync = 1'b0;
            yb_sync = 1'b0;
            if (!act || se0) begin
                hunt_a = 1'b1; hist_a = 16'hFFFF;
                hunt_b = 1'b1; hist_b = 16'hFFFF;
            end else begin
                if (hunt_a && b) begin
                    if (hist_a[5:0] == 6'b000000) begin ya_sync = 1'b1; hunt_a = 1'b0; hits_a = hits_a + 1; end
                    else if (hist_a[4:0] == 5'b00000 && hist_a[5]) near_a = near_a + 1;
                end
                if (hunt_b && b) begin
                    if (hist_b[3:0] == 4'b0000) begin yb_sync = 1'b1; hunt_b = 1'b0; hits_b = hits_b + 1; end
                    else if (hist_b[2:0] == 3'b000 && hist_b[3]) near_b = near_b + 1;
                end
                hist_a = {hist_a[14:0], b};
                hist_b = {hist_b[14:0], b};
                if (!hunt_a) hist_a = 16'hFFFF;
                if (!hunt_b) hist_b = 16'hFFFF;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if ((a_en !== x_valid) || (b_en !== x_valid)) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_en wrong", $time);
            end
            if (!a_en && (a_sync || b_sync)) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_sync without a strobe", $time);
            end
            if (x_valid) begin
                if ((a_bit !== x_bit) || (a_se0 !== x_se0) || (a_act !== x_act) ||
                    (b_bit !== x_bit) || (b_se0 !== x_se0) || (b_act !== x_act)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: bit/se0/act not passed through", $time);
                end
                if ((a_sync !== xa_sync) || (a_pkt !== xa_pkt)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: ZMIN=6: sync=%b pkt=%b, expected %b %b", $time, a_sync, a_pkt, xa_sync, xa_pkt);
                end
                if ((b_sync !== xb_sync) || (b_pkt !== xb_pkt)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: ZMIN=4: sync=%b pkt=%b, expected %b %b", $time, b_sync, b_pkt, xb_sync, xb_pkt);
                end
            end
        end
    end

    task bit_out(input b, input se0, input act);
        begin
            if ({$random(seed)} % 4 == 0) begin            // strobe gap
                @(negedge clk);
                i_en  = 1'b0;
                i_bit = $random(seed);
                @(posedge clk); #0.1;
                x_valid = 1'b0;
            end
            @(negedge clk);
            i_en = 1'b1; i_bit = b; i_se0 = se0; i_act = act;
            model(b, se0, act);
            y_bit = b; y_se0 = se0; y_act = act;
            @(posedge clk); #0.1;
            x_valid = 1'b1;
            x_bit = y_bit; x_se0 = y_se0; x_act = y_act;
            xa_sync = ya_sync; xa_pkt = ya_pkt; xb_sync = yb_sync; xb_pkt = yb_pkt;
        end
    endtask

    task zeros(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) bit_out(1'b0, 1'b0, 1'b1);
        end
    endtask

    integer p, i, k;

    initial begin
        $dumpfile("tb_usb_rx_sync_detect.vcd");
        $dumpvars(0, tb_usb_rx_sync_detect);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        $display("Directed: SYNC lengths 0..12 zeros, rearm by SE0");
        for (k = 0; k <= 12; k = k + 1) begin
            for (i = 0; i < 3; i = i + 1) bit_out(1'b1, 1'b0, 1'b1);    // idle
            zeros(k);
            bit_out(1'b1, 1'b0, 1'b1);                                  // end of SYNC?
            zeros(10);                                                  // body: long zero run
            bit_out(1'b1, 1'b0, 1'b1);                                  // must not trigger
            bit_out(1'b0, 1'b1, 1'b1);                                  // SE0 -> rearm
            bit_out(1'b0, 1'b1, 1'b1);
        end

        $display("Directed: rearm by inactive bits");
        zeros(8); bit_out(1'b1, 1'b0, 1'b1);
        zeros(8); bit_out(1'b1, 1'b0, 1'b1);
        bit_out(1'b0, 1'b0, 1'b0);                                      // inactive
        zeros(8); bit_out(1'b1, 1'b0, 1'b1);                            // new hit
        zeros(3); bit_out(1'b0, 1'b0, 1'b0);                            // zeros cut by inactive
        zeros(3); bit_out(1'b1, 1'b0, 1'b1);                            // 3 zeros only: no hit

        $display("Random streams");
        for (p = 0; p < 600; p = p + 1) begin
            k = {$random(seed)} % 4;
            for (i = 0; i < 1 + {$random(seed)} % 5; i = i + 1) bit_out(1'b1, 1'b0, 1'b1);
            zeros({$random(seed)} % 10);
            bit_out(1'b1, 1'b0, 1'b1);
            for (i = 0; i < {$random(seed)} % 40; i = i + 1)
                bit_out(({$random(seed)} % 3) == 0, 1'b0, 1'b1);
            if (k == 0)      bit_out(1'b0, 1'b1, 1'b1);
            else if (k == 1) bit_out(1'b0, 1'b0, 1'b0);
        end

        @(negedge clk) i_en = 1'b0;
        @(posedge clk); #0.1;
        x_valid = 1'b0;
        repeat (5) @(posedge clk);
        $display("ZMIN=6: %0d hits, %0d near misses;  ZMIN=4: %0d hits, %0d near misses",
                 hits_a, near_a, hits_b, near_b);
        if (hits_a < 50 || hits_b < 50 || near_a < 20 || near_b < 20) begin
            errors = errors + 1;
            $display("ERROR: not enough coverage of hits / near misses");
        end
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
