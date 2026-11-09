//-----------------------------------------------------------------------------
// tb_usb_rx_bit_unstuffer.v - self-checking testbench for usb_rx_bit_unstuffer
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxuns usb_rx_bit_unstuffer.v tb_usb_rx_bit_unstuffer.v
//   vvp sim_rxuns
//
// Packets: the final 1 of SYNC (i_sync), then data bits stuffed by a
// testbench model of the TX rule (a 0 after six 1s; the SYNC 1 counts as the
// first one; a stuff bit also after six final 1s), then an SE0 or an inactive
// bit.  Data is biased towards long runs of 1s.  Some packets get a violation:
// one stuff 0 is sent as 1.  Bits outside packets (i_pkt = 0) and random
// strobe gaps are mixed in.  Checked:
//   * the o_dat bits of every packet are exactly the data bits;
//   * o_serr exactly on the injected violation (none elsewhere); after it both
//     the DUT and the model restart the run count at 0, so the rest of the
//     packet is checked as well;
//   * no o_dat / o_serr outside packets (i_pkt = 0, SE0, inactive, SYNC bit);
//   * sideband (en, se0, act, sync, pkt) passed through with one cycle of latency.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_bit_unstuffer;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n;

    reg  i_en = 1'b0, i_bit = 1'b1, i_se0 = 1'b0, i_act = 1'b1, i_sync = 1'b0, i_pkt = 1'b0;
    wire o_en, o_dat, o_bit, o_serr, o_se0, o_act, o_sync, o_pkt;

    usb_rx_bit_unstuffer dut (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_bit (i_bit), .i_se0 (i_se0), .i_act (i_act),
        .i_sync (i_sync), .i_pkt (i_pkt),
        .o_en (o_en), .o_dat (o_dat), .o_bit (o_bit), .o_serr (o_serr),
        .o_se0 (o_se0), .o_act (o_act), .o_sync (o_sync), .o_pkt (o_pkt)
    );

    integer errors = 0;
    integer seed   = 32'h55AA_1234;

    // expectation for the bit of the last strobe
    //   kind 0: not data, 1: data bit (x_b), 2: stuff bit (dropped), 3: violation
    reg     x_valid = 1'b0, x_b, x_se0, x_act, x_sync, x_pkt;
    integer x_kind;
    integer dbits = 0, stuffs = 0, viols = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (o_en !== x_valid) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_en wrong", $time);
            end
            if (!o_en && (o_dat || o_serr)) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_dat / o_serr without a strobe", $time);
            end
            if (x_valid) begin
                if ((o_se0 !== x_se0) || (o_act !== x_act) || (o_sync !== x_sync) || (o_pkt !== x_pkt)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: sideband not passed through", $time);
                end
                begin
                    case (x_kind)
                        0: if (o_dat || o_serr) begin
                               errors = errors + 1;
                               $display("ERROR @%0t: data/serr on a non-data bit", $time);
                           end
                        1: if (!o_dat || o_serr || (o_bit !== x_b)) begin
                               errors = errors + 1;
                               $display("ERROR @%0t: data bit: dat=%b serr=%b bit=%b, expected %b",
                                        $time, o_dat, o_serr, o_bit, x_b);
                           end
                        2: if (o_dat || o_serr) begin
                               errors = errors + 1;
                               $display("ERROR @%0t: stuff bit not dropped (dat=%b serr=%b)", $time, o_dat, o_serr);
                           end
                        3: if (!o_serr || o_dat) begin
                               errors = errors + 1;
                               $display("ERROR @%0t: violation not flagged", $time);
                           end
                    endcase
                end
            end
        end
    end

    task bit_out(input b, input se0, input act, input sync, input pkt, input integer kind);
        begin
            if ({$random(seed)} % 4 == 0) begin
                @(negedge clk);
                i_en = 1'b0; i_bit = $random(seed);
                @(posedge clk); #0.1;
                x_valid = 1'b0;
            end
            @(negedge clk);
            i_en = 1'b1; i_bit = b; i_se0 = se0; i_act = act; i_sync = sync; i_pkt = pkt;
            @(posedge clk); #0.1;
            x_valid = 1'b1;
            x_b = b; x_se0 = se0; x_act = act; x_sync = sync; x_pkt = pkt; x_kind = kind;
        end
    endtask

    // one packet: SYNC 1, n stuffed data bits, end; viol >= 0: stuff bit no. viol becomes 1
    task packet(input integer n, input integer viol, input integer endkind);
        integer i, ones, ns;
        reg b;
        begin
            bit_out(1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 0);             // final 1 of SYNC
            ones = 1;
            ns   = 0;
            for (i = 0; i < n; i = i + 1) begin
                b = ({$random(seed)} % 8) != 0;                   // mostly ones
                bit_out(b, 1'b0, 1'b1, 1'b0, 1'b1, 1);
                dbits = dbits + 1;
                ones = b ? ones + 1 : 0;
                if (ones == 6) begin
                    if (ns == viol) begin
                        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 3);
                        viols    = viols + 1;
                    end else begin
                        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 2);
                        stuffs = stuffs + 1;
                    end
                    ns   = ns + 1;
                    ones = 0;
                end
            end
            if (endkind == 0) bit_out(1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 0);   // SE0
            else              bit_out(1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 0);   // inactive
        end
    endtask

    task outside(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 0);         // idle ones, not in a packet
        end
    endtask

    integer p;

    initial begin
        $dumpfile("tb_usb_rx_bit_unstuffer.vcd");
        $dumpvars(0, tb_usb_rx_bit_unstuffer);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        $display("Directed: SYNC 1 counts, stuff after six final ones");
        outside(10);
        // after SYNC: 5 ones -> stuff 0, then 0
        bit_out(1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 0);
        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 2);                  // stuff
        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        // six ones at the very end + stuff bit, then SE0
        repeat (6) bit_out(1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1);
        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 2);
        bit_out(1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 0);

        $display("Random packets, some with violations");
        for (p = 0; p < 400; p = p + 1) begin
            outside({$random(seed)} % 12);                         // > 6 ones outside: no error
            packet(1 + {$random(seed)} % 80,
                   ({$random(seed)} % 4 == 0) ? ({$random(seed)} % 4) : -1,
                   {$random(seed)} % 2);
        end

        @(negedge clk) i_en = 1'b0;
        @(posedge clk); #0.1;
        x_valid = 1'b0;
        repeat (5) @(posedge clk);
        $display("%0d data bits, %0d stuff bits, %0d violations", dbits, stuffs, viols);
        if (viols < 20 || stuffs < 200) begin
            errors = errors + 1;
            $display("ERROR: not enough coverage");
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
