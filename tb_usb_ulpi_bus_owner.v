//-----------------------------------------------------------------------------
// tb_usb_ulpi_bus_owner.v - self-checking testbench for usb_ulpi_bus_owner
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_bus usb_ulpi_bus_owner.v tb_usb_ulpi_bus_owner.v
//   vvp sim_bus
//
// The bench plays the Output Arbiter (byte bursts with arb_valid / arb_data /
// arb_is_data) and the TX / register side (tx_busy, tx_nxt_n, reg_nxt_n noise).
// A pin-level monitor, which sees only DIR / NXT / DATA / OE like the Link, checks:
//   * every burst byte appears on the pins in order, with NXT = arb_is_data;
//   * turnaround: the first DIR = 1 tick is undriven (oe = 0), no bubbles inside a
//     burst, DIR falls the tick after the last byte, oe only while DIR is high;
//   * NXT is low in the turnaround ticks (DIR = 1 without data, and the two ticks
//     after DIR falls);
//   * arbitration: DIR rises only if in the decision tick the TX side was quiet
//     (tx_busy = 0, no NXT on the pin in that and the previous tick, no NXT request);
//   * NXT pass-through: in the Link-owned state NXT = tx_nxt_n | reg_nxt_n of the
//     previous tick;
//   * dir_hold keeps DIR high without driving the bus, and bursts still go through.
//
//   ce_mode : 0 = always, 1 = one tick in eight, 2 = random 50 %
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_bus_owner;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    reg ce = 1'b1;

    reg        tx_nxt_n    = 1'b0;
    reg        reg_nxt_n   = 1'b0;
    reg        tx_busy     = 1'b0;
    reg        arb_valid   = 1'b0;
    reg [7:0]  arb_data    = 8'd0;
    reg        arb_is_data = 1'b0;
    wire       arb_ready;
    reg        dir_hold    = 1'b0;
    wire       dir_q, nxt_q, oe_q;
    wire [7:0] data_q;

    usb_ulpi_bus_owner dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .ce          (ce),
        .tx_nxt_n    (tx_nxt_n),
        .reg_nxt_n   (reg_nxt_n),
        .tx_busy     (tx_busy),
        .arb_valid   (arb_valid),
        .arb_data    (arb_data),
        .arb_is_data (arb_is_data),
        .arb_ready   (arb_ready),
        .dir_hold    (dir_hold),
        .dir_q       (dir_q),
        .nxt_q       (nxt_q),
        .data_q      (data_q),
        .oe_q        (oe_q)
    );

    integer errors  = 0;
    integer ce_mode = 0;
    integer ce_ph   = 0;
    integer seed_ce = 32'h4242_4242;
    integer seed    = 32'h2424_2424;

    always @(negedge clk) begin
        case (ce_mode)
            0: ce <= 1'b1;
            1: begin
                   ce    <= (ce_ph == 7);
                   ce_ph <= (ce_ph + 1) % 8;
               end
            default: ce <= (({$random(seed_ce)} % 2) == 1);
        endcase
    end

    // ---------------- expected PHY bytes ----------------
    reg [7:0] exp_b [0:4095];
    reg       exp_d [0:4095];
    integer   exp_n   = 0;
    integer   obs_idx = 0;

    // ---------------- noise on the TX / register side ----------------
    reg     noise_en  = 1'b0;
    integer noise_cnt = 0;
    reg [31:0] nr;

    always @(negedge clk) begin
        if (noise_en && ce) begin
            nr = $random(seed);
            if (noise_cnt == 0) begin
                tx_busy   <= ~tx_busy;
                noise_cnt <= 5 + (nr[15:8] % 36);
            end else begin
                noise_cnt <= noise_cnt - 1;
            end
            tx_nxt_n  <= (nr[2:0] == 3'd0) && !tx_busy;
            reg_nxt_n <= (nr[6:4] == 3'd0);
        end
    end

    // ---------------- arbiter source ----------------
    task send_burst(input integer n, input integer gap_after);
        integer i;
        reg     acc;
        reg [31:0] r;
        begin
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                exp_b[exp_n] = r[7:0];
                exp_d[exp_n] = r[8];
                exp_n        = exp_n + 1;
                arb_data     = r[7:0];
                arb_is_data  = r[8];
                arb_valid    = 1'b1;
                acc = 1'b0;
                while (!acc) begin
                    @(posedge clk);
                    if (arb_ready) acc = 1'b1;           // pre-edge value
                end
                @(negedge clk);
            end
            arb_valid = 1'b0;
            repeat (gap_after) @(negedge clk);
        end
    endtask

    task wait_all_delivered;
        begin
            while (obs_idx != exp_n) @(posedge clk);
            repeat (20) @(posedge clk);
        end
    endtask

    // ---------------- pin-level monitor ----------------
    reg       prev_dir   = 1'b0;
    integer   nxt_zero   = 0;            // ticks after DIR fell in which NXT must stay low
    reg       txbusy_p = 1'b0, nxt_p = 1'b0, nxt_pp = 1'b0, txn_p = 1'b0, regn_p = 1'b0;
    reg       chk_pass   = 1'b0;         // NXT pass-through check (phase A)
    reg       pass_exp   = 1'b0;
    reg       pass_valid = 1'b0;
    reg       hold_mode  = 1'b0;         // dir_hold in use: bubbles allowed

    always @(posedge clk) begin
        if (rst_n && ce) begin
            // oe only while DIR is high
            if (oe_q && !dir_q) begin
                errors = errors + 1;
                $display("ERROR @%0t: oe_q without DIR", $time);
            end
            // burst bytes
            if (oe_q) begin
                if (obs_idx >= exp_n) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: unexpected byte %02h on the pins", $time, data_q);
                end else begin
                    if (data_q !== exp_b[obs_idx]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: byte %0d = %02h, expected %02h", $time, obs_idx, data_q, exp_b[obs_idx]);
                    end
                    if (nxt_q !== exp_d[obs_idx]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: NXT = %b with byte %0d, expected %b", $time, nxt_q, obs_idx, exp_d[obs_idx]);
                    end
                    obs_idx = obs_idx + 1;
                end
            end
            // NXT must be low while DIR is high and no byte is driven (turnaround / idle hold)
            if (dir_q && !oe_q && nxt_q) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT high in an undriven DIR tick", $time);
            end
            // rising DIR: first tick undriven, and the TX side must have been quiet before
            if (dir_q && !prev_dir) begin
                if (oe_q) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: bus driven in the first DIR tick (no turnaround)", $time);
                end
                if (txbusy_p || nxt_p || nxt_pp || txn_p || regn_p) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose while the TX side was active (busy=%b nxt=%b nxt_prev=%b txn=%b regn=%b)",
                             $time, txbusy_p, nxt_p, nxt_pp, txn_p, regn_p);
                end
            end
            // no bubble inside a burst
            if (!hold_mode && dir_q && prev_dir && !oe_q) begin
                errors = errors + 1;
                $display("ERROR @%0t: bubble inside a burst", $time);
            end
            // falling DIR: NXT stays low for two ticks
            if (!dir_q && prev_dir) nxt_zero = 2;
            if (nxt_zero > 0) begin
                if (nxt_q) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: NXT high right after DIR fell", $time);
                end
                nxt_zero = nxt_zero - 1;
            end
            // NXT pass-through in the Link-owned state
            if (chk_pass) begin
                if (pass_valid && (nxt_q !== pass_exp)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: NXT = %b, expected %b (tx_nxt_n | reg_nxt_n of the previous tick)",
                             $time, nxt_q, pass_exp);
                end
                pass_exp   = tx_nxt_n | reg_nxt_n;
                pass_valid = 1'b1;
                if (dir_q) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose without any PHY request", $time);
                end
            end else begin
                pass_valid = 1'b0;
            end

            // history for the next tick
            prev_dir = dir_q;
            nxt_pp   = nxt_p;
            nxt_p    = nxt_q;
            txbusy_p = tx_busy;
            txn_p    = tx_nxt_n;
            regn_p   = reg_nxt_n;
        end
    end

    // ---------------- stimulus ----------------
    integer cm, p, nb;

    initial begin
        $dumpfile("tb_usb_ulpi_bus_owner.vcd");
        $dumpvars(0, tb_usb_ulpi_bus_owner);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);

        for (cm = 0; cm < 3; cm = cm + 1) begin
            ce_mode = cm;
            $display("--- ce_mode = %0d ---", cm);

            // ---- A: NXT pass-through, no PHY traffic ----
            $display("A: NXT pass-through");
            chk_pass = 1'b1;
            noise_en = 1'b1;
            tx_busy  = 1'b0;
            noise_cnt = 1000000;                    // keep tx_busy low during this phase
            repeat (300) @(posedge clk);
            noise_en = 1'b0;
            tx_nxt_n = 1'b0;
            reg_nxt_n = 1'b0;
            repeat (20) @(posedge clk);
            chk_pass = 1'b0;
            @(negedge clk);

            // ---- B: directed bursts, TX side quiet ----
            $display("B: directed bursts");
            send_burst(1, 6);
            send_burst(2, 6);
            send_burst(8, 6);
            send_burst(3, 0);                       // merges with the next one
            send_burst(3, 9);
            wait_all_delivered;
            @(negedge clk);

            // ---- C: random bursts against TX / register noise ----
            $display("C: random bursts with TX noise");
            noise_en  = 1'b1;
            noise_cnt = 0;
            for (p = 0; p < 20; p = p + 1) begin
                nb = 1 + ({$random(seed)} % 8);
                send_burst(nb, {$random(seed)} % 30);
            end
            wait_all_delivered;
            noise_en  = 1'b0;
            tx_busy   = 1'b0;
            tx_nxt_n  = 1'b0;
            reg_nxt_n = 1'b0;
            repeat (20) @(posedge clk);
            @(negedge clk);

            // ---- D: dir_hold ----
            $display("D: dir_hold");
            hold_mode = 1'b1;
            dir_hold  = 1'b1;
            repeat (30) @(posedge clk);
            #1;
            if (dir_q !== 1'b1 || oe_q !== 1'b0 || nxt_q !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: dir_hold: DIR=%b oe=%b NXT=%b", $time, dir_q, oe_q, nxt_q);
            end
            @(negedge clk);
            send_burst(4, 5);                        // bursts still go through while held
            wait_all_delivered;
            @(negedge clk);
            dir_hold = 1'b0;
            repeat (30) @(posedge clk);
            #1;
            if (dir_q !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: DIR still high after dir_hold was released", $time);
            end
            hold_mode = 1'b0;
            @(negedge clk);
        end

        // ---------------- final checks ----------------
        repeat (20) @(posedge clk);
        if (obs_idx != exp_n) begin
            errors = errors + 1;
            $display("ERROR: %0d bytes sent, %0d seen on the pins", exp_n, obs_idx);
        end

        $display("--------------------------------------------------");
        $display("PHY bytes delivered: %0d", obs_idx);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
