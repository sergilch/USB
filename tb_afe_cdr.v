//-----------------------------------------------------------------------------
// tb_afe_cdr.v - unit testbench for afe_cdr_bm (bang-bang CDR): lock time and
//                tracking
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_cdr afe_cdr_bm.v tb_afe_cdr.v
//   vvp sim_afe_cdr
//
// Stimulus: bursts of a 32-bit SYNC (one transition per bit) followed by
// random data with at most 7 equal bits in a row (HS bit stuffing), on the far
// transmitter's clock (ppm offset), with a uniform random edge jitter of +-DJ
// (DJ = 0.15 UI leaves a 70 % eye).  Each burst starts at a random time after
// an idle gap, so the CDR, which free-runs in between, sees a random phase.
// During idle the data line either holds its level or toggles at random
// (receiver noise on an idle line).
//
// Check: on every rising clk_rx edge the testbench maps the sampling time onto
// the nominal (jitter-free) bit interval of the transmitted stream and compares
// hs_rxd (T_CQ later) with that bit.  A sample is bad if the value is wrong or
// if bits were skipped / sampled twice (slip).  Per burst:
//   lock bits L = index of the first bit after which every sample is good.
//
// Checked
//   [1] Free-running frequency without transitions (PPM parameter).
//   [2] Default loop (STEP 0.13 ns ~ UI/16), DJ 0.15 UI, +-1000 ppm, both
//       idle styles, 300 bursts each: no bad sample after the SYNC (bit 32
//       on), worst L <= L_MAX (a sanity bound for the model; the share of
//       bursts that miss the 4 / 6 bit SYNC budgets is reported).
//   [3] Long burst (9,500 bits, about one maximum-size HS packet) at +1000 ppm
//       and -1000 ppm: no bad sample after lock.
//   [4] Report only (no pass / fail): worst / mean L over STEP UI/32, UI/16,
//       UI/8 and DJ 0 / 0.15 / 0.25 UI.  This is the table that goes into
//       DOC/afe_interface_spec.md 4.2.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_afe_cdr;
    parameter real    T_BIT = 2.0833333;
    parameter integer L_MAX = 24;           // model sanity bound (random-walk tail), default loop
    integer errors = 0;
    integer seed   = 7;

    reg  data = 1'b0, cdr_en = 1'b0;
    wire clk_rx, hs_rxd;
    wire [31:0] n_up, n_dn, n_bits;

    afe_cdr_bm #(.T_BIT(T_BIT)) u_cdr (.CDR_DATA(data), .CDR_EN(cdr_en), .clk_rx(clk_rx),
                                       .hs_rxd(hs_rxd), .n_up(n_up), .n_dn(n_dn), .n_bits(n_bits));

    // ---------------- transmitted burst ----------------
    localparam integer NMAX = 10000;
    reg     bits [0:NMAX-1];
    integer nbits   = 0;
    real    t0      = 0.0;      // nominal start of bit 0 (after the DJ latency)
    real    tf      = T_BIT;    // far bit time
    real    dj      = 0.0;      // ns
    reg     active  = 1'b0;     // burst on the line (checker on)
    reg     idle_noise = 1'b0;

    task make_burst(input integer n);
        integer k, run;
        reg     b, prev;
        begin
            nbits = n;
            prev  = data;
            run   = 0;
            for (k = 0; k < n; k = k + 1) begin
                if (k < 32) b = (k == 31) ? prev : !prev;     // SYNC: KJKJ...KK
                else begin
                    b = $random(seed);
                    if ((b == prev) && (run >= 6)) b = !prev; // at most 7 equal bits
                end
                run = (b == prev) ? run + 1 : 0;
                bits[k] = b;
                prev = b;
            end
        end
    endtask

    // send the prepared burst; returns when the last bit is over
    task send_burst;
        integer k;
        real    j, tn;
        begin
            t0 = $realtime + dj;
            active = 1'b1;
            for (k = 0; k < nbits; k = k + 1) begin
                j = (dj > 0.0) ? dj * (($random(seed) % 10000) / 10000.0) : 0.0;
                data <= #(dj + j) bits[k];
                tn = t0 - dj + (k + 1) * tf;
                #(tn - $realtime);
            end
            #(dj + 1.0);
            active = 1'b0;
        end
    endtask

    task idle(input real t);
        real tend;
        begin
            tend = $realtime + t;
            if (!idle_noise) #(t);
            else while ($realtime < tend) begin
                #(0.5 + ({$random(seed)} % 3000) / 1000.0);
                data = $random(seed);
            end
        end
    endtask

    // ---------------- checker ----------------
    integer last_k, last_bad, n_bad_late;
    real    ts;
    integer k_s;
    always @(posedge clk_rx) if (active) begin
        ts  = $realtime;
        k_s = $rtoi((ts - t0) / tf + 1000.0) - 1000;   // floor, also below 0
        #(0.35);
        if ((k_s >= 0) && (k_s < nbits)) begin
            if ((hs_rxd !== bits[k_s]) || ((last_k >= 0) && (k_s != last_k + 1))) begin
                last_bad = k_s;
                if (k_s >= 32) n_bad_late = n_bad_late + 1;
            end
            last_k = k_s;
        end
    end

    // one burst at random phase; returns the lock bits
    task burst(input integer n, output integer lock);
        begin
            last_k = -1; last_bad = -1;
            idle(40.0 + ({$random(seed)} % 100000) / 1000.0);
            make_burst(n);
            send_burst;
            lock = last_bad + 1;
        end
    endtask

    // statistics over nb bursts
    // worst / sum of L, bursts with L > 4 and L > 6 (the SYNC budgets of
    // DOC/afe_interface_spec.md 4.2 for HS_ZMIN 6 / 4), bad samples after SYNC
    integer worst, sum, lk, bi, late_tot, n_gt4, n_gt6;
    task run_set(input integer nb, input integer n);
        begin
            worst = 0; sum = 0; late_tot = 0; n_gt4 = 0; n_gt6 = 0;
            for (bi = 0; bi < nb; bi = bi + 1) begin
                n_bad_late = 0;
                burst(n, lk);
                late_tot = late_tot + n_bad_late;
                sum = sum + lk;
                if (lk > worst) worst = lk;
                if (lk > 4) n_gt4 = n_gt4 + 1;
                if (lk > 6) n_gt6 = n_gt6 + 1;
            end
        end
    endtask

    task set_far_ppm(input real ppm);
        begin tf = T_BIT * (1.0 + ppm * 1.0e-6); end
    endtask

    integer si, di, nb0, nb1;
    real    steps [0:2];
    real    djs   [0:2];
    real    tm;

    initial begin
        $dumpfile("tb_afe_cdr.vcd");
        $dumpvars(0, tb_afe_cdr);
        steps[0] = T_BIT / 32.0; steps[1] = T_BIT / 16.0; steps[2] = T_BIT / 8.0;
        djs[0]   = 0.0; djs[1] = 0.15 * T_BIT; djs[2] = 0.25 * T_BIT;

        $display("[1] Free-running frequency");
        cdr_en = 1'b1;
        #100;
        nb0 = n_bits; tm = $realtime;
        #10000;
        nb1 = n_bits;
        $display("  %0d clk_rx cycles in 10 us (nominal %0.1f)", nb1 - nb0, 10000.0 / T_BIT);
        if (((nb1 - nb0) < 4799) || ((nb1 - nb0) > 4801)) begin
            errors = errors + 1; $display("ERROR: free-running frequency");
        end

        $display("[2] Default loop, DJ 0.15 UI, +-1000 ppm, 300 bursts per case");
        dj = 0.15 * T_BIT;
        for (si = 0; si < 4; si = si + 1) begin
            set_far_ppm((si % 2) ? -1000.0 : 1000.0);
            idle_noise = (si >= 2);
            run_set(300, 120);
            $display("  %0s ppm, idle %0s: lock bits worst %0d, mean %0.2f, > 4: %0.1f %%, > 6: %0.1f %%; bad samples after SYNC %0d",
                     (si % 2) ? "-1000" : "+1000", idle_noise ? "noise" : "quiet",
                     worst, sum / 300.0, n_gt4 / 3.0, n_gt6 / 3.0, late_tot);
            if ((worst > L_MAX) || (late_tot != 0)) begin
                errors = errors + 1; $display("ERROR: lock time / tracking");
            end
        end

        $display("[3] Long bursts, 9500 bits, DJ 0.15 UI");
        for (si = 0; si < 2; si = si + 1) begin
            set_far_ppm(si ? -1000.0 : 1000.0);
            idle_noise = 1'b0;
            n_bad_late = 0;
            burst(9500, lk);
            $display("  %0s ppm: lock bits %0d, bad samples after SYNC %0d (up %0d / down %0d decisions)",
                     si ? "-1000" : "+1000", lk, n_bad_late, n_up, n_dn);
            if ((lk > L_MAX) || (n_bad_late != 0)) begin
                errors = errors + 1; $display("ERROR: long burst");
            end
        end

        $display("[4] Lock bits vs. loop step and jitter (+1000 ppm, quiet idle, 300 bursts)");
        $display("      STEP           DJ 0 UI               DJ 0.15 UI            DJ 0.25 UI       (worst / mean / %% of bursts with L > 6)");
        set_far_ppm(1000.0);
        idle_noise = 1'b0;
        for (si = 0; si < 3; si = si + 1) begin
            u_cdr.STEP = steps[si];
            $write("  %0.3f ns (UI/%0d)", steps[si], (si == 0) ? 32 : (si == 1) ? 16 : 8);
            for (di = 0; di < 3; di = di + 1) begin
                dj = djs[di];
                run_set(300, 80);
                $write("   %3d / %5.2f / %4.1f %%", worst, sum / 300.0, n_gt6 / 3.0);
            end
            $write("\n");
        end
        u_cdr.STEP = 0.13;

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
