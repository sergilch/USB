//-----------------------------------------------------------------------------
// tb_usb_pll_lock_det.v - PLL lock detector and CLKOUT generator with a PLL model
//                         (phase A4)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_pll_lock_det usb_pll_lock_det.v usb_clk_gen.v \
//            afe_pll_bm.v tb_usb_pll_lock_det.v
//   vvp sim_pll_lock_det
//
// Setup: a reference clock (f_ref, ppm, can be stopped) drives afe_pll_bm
// (first-order frequency settling, TAU 5 us, VCO 400-500 MHz, divider = the
// DUT's fb_div); its output is clk_bit for usb_pll_lock_det and usb_clk_gen
// (clk_en = pll_lock & !clk_susp).
//
// Checked all the time
//   * clk60 (CLKOUT): every high phase exactly 4 clk_bit cycles, every low phase
//     4 + 8k cycles (complete periods only, stops low), each rising edge half a
//     cycle before a clk_bit edge with ce60 = 1; ce60 exactly every 8 cycles;
//     no rising edge unless clk_en was 1 at the decision point; clk_on = 0 only
//     while clk60 is low (safe point to stop the PLL).
//   * pll_lock never rises while the PLL ratio was grossly off (> 0.3 %) in the
//     last 3 windows (the window in which an error ends can still average
//     inside the tolerance), and never while it is off by more than 0.12 % now.
// Cases
//   [1] reset values; fb_div / refsel_err for all four refsel codes
//   [2] 24 MHz + 300 ppm: lock within 5 windows after the PLL settles inside
//       +-0.08 %, and <= 100 us after pll_en (spec 4.3); CLKOUT starts after lock
//   [3] CLKOUT stop / start (clock suspend) at random phases: glitch-free
//   [4] +0.05 % frequency error (inside the tolerance): lock is kept
//   [5] +0.3 % error: lock lost within 2 windows, lol set, CLKOUT stops cleanly;
//       relock; lol stays until lol_clr
//   [6] reference stops: lock lost within the counter timeout + 1 window
//   [7] clk_bit stops (VCO failure) with pll_en = 1: lock falls within 2 us;
//       lol is set once the clock is back
//   [8] ordered PLL switch-off (CLKOUT first, then pll_en): lock falls at once,
//       lol not set; restart and relock
//   [9] 19.2 MHz with refsel 00 (fb_div 25): lock; -500 ppm reference: lock
//  [10] wrong reference (26 MHz with refsel 01): the PLL hits its VCO limit and
//       never locks
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_pll_lock_det;
    integer errors = 0;
    integer seed   = 32'h0A4C_1C0C;

    // ---------------- reference ----------------
    real f_ref   = 24.0;              // MHz, nominal
    real ref_ppm = 300.0;
    reg  ref_run = 1'b1;
    reg  ref_clk = 1'b0;
    real rh;
    always begin
        rh = 500.0 / (f_ref * (1.0 + ref_ppm * 1.0e-6));
        if (ref_run) begin #(rh) ref_clk = ~ref_clk; end
        else begin ref_clk = 1'b0; wait (ref_run); end
    end

    // ---------------- DUTs + PLL ----------------
    reg        rst_n = 1'b0, pll_en = 1'b0, clk_susp = 1'b0, lol_clr = 1'b0;
    reg  [1:0] refsel = 2'b01;
    wire       clk_bit, pll_lock, lol, refsel_err, ce60, clk60, clk_on;
    wire [4:0] fb_div;
    wire       clk_en = pll_lock & !clk_susp;

    afe_pll_bm u_pll (.CDR_FREF(ref_clk), .PLL_EN(pll_en), .clk_out(clk_bit));
    always @(fb_div) if (fb_div != 5'd0) u_pll.DIV = fb_div;

    usb_pll_lock_det dut (
        .clk_bit(clk_bit), .ref_clk(ref_clk), .rst_n(rst_n), .pll_en(pll_en),
        .refsel(refsel), .lol_clr(lol_clr),
        .pll_lock(pll_lock), .lol(lol), .fb_div(fb_div), .refsel_err(refsel_err));
    usb_clk_gen u_cg (.clk_bit(clk_bit), .rst_n(rst_n), .clk_en(clk_en),
                      .ce60(ce60), .clk60(clk60), .clk_on(clk_on));

    // window length in ns at the nominal reference
    function real W; input dummy; W = 256.0 * 1000.0 / f_ref; endfunction

    // =====================================================================
    // CLKOUT monitor (on clk_bit)
    // =====================================================================
    integer hi_cnt = 0, lo_cnt = 0, ce_gap = 0, ck_err = 0, n_pulse = 0;
    reg     c60_q = 1'b0, rose = 1'b0;
    reg     en_h1 = 1'b0, en_h2 = 1'b0;          // clk_en at the last two edges
    reg     cg_started = 1'b0;

    task ckerr(input [8*48-1:0] m);
        begin
            ck_err = ck_err + 1;
            if (ck_err <= 20) $display("ERROR @%0t: CLKOUT: %0s (high %0d, low %0d)", $time, m, hi_cnt, lo_cnt);
        end
    endtask


    always @(posedge clk_bit) begin
        if (rst_n) begin
            // ce60 period
            if (ce60) begin
                if (cg_started && (ce_gap != 7)) ckerr("ce60 not every 8 cycles");
                ce_gap = 0; cg_started = 1'b1;
            end else ce_gap = ce_gap + 1;
            // clk60 changes at negedges, so at a posedge it is stable: classify the
            // cycle that ends here; a transition shows as clk60 != c60_q
            if (clk60 && !c60_q) begin                 // rose half a cycle ago
                if (!ce60) ckerr("clk60 rise not in a ce60 cycle");
                if (!en_h1) ckerr("clk60 rise without clk_en");
                if ((n_pulse > 0) && (lo_cnt % 8 != 4)) ckerr("low phase not 4 + 8k cycles");
                hi_cnt = 1; lo_cnt = 0; n_pulse = n_pulse + 1;
            end else if (!clk60 && c60_q) begin        // fell half a cycle ago
                if (hi_cnt != 4) ckerr("high phase not 4 cycles");
                hi_cnt = 0; lo_cnt = 1;
            end else if (clk60) begin
                hi_cnt = hi_cnt + 1;
                if (hi_cnt > 4) ckerr("high phase too long");
            end else
                lo_cnt = lo_cnt + 1;
            c60_q = clk60;
            // clk_on = 0 must mean CLKOUT is low and stays low (safe to stop the PLL)
            if (!clk_on && clk60) ckerr("clk60 high while clk_on = 0");
            en_h2 = en_h1; en_h1 = clk_en;
        end
    end

    // =====================================================================
    // PLL ratio tracking (every 50 ns)
    // =====================================================================
    real err_now = 1.0, t_out3 = 0.0, t_notin = 0.0;
    real r_exp;
    integer lk_err = 0;
    always #50 begin
        r_exp = (refsel == 2'b00) ? 25.0 : 20.0;
        if (pll_en && !u_pll.dead && ref_run && (clk_bit !== 1'bx))
            err_now = u_pll.f_now * (1.0 + u_pll.f_off) / (f_ref * (1.0 + ref_ppm * 1.0e-6)) / r_exp - 1.0;
        else
            err_now = 1.0;
        if (err_now < 0.0) err_now = -err_now;
        if (err_now > 0.003)   t_out3  = $realtime;
        if (err_now >= 0.0008) t_notin = $realtime;
    end

    real t_lock_rise = 0.0;
    always @(posedge pll_lock) begin
        t_lock_rise = $realtime;
        if (($realtime - t_out3 < 3.0 * W(0)) || (err_now > 0.0012)) begin
            lk_err = lk_err + 1;
            $display("ERROR @%0t: false lock (error now %0.4f %%, gross error %0.1f us ago)",
                     $time, 100.0 * err_now, ($realtime - t_out3) / 1000.0);
        end
    end

    // =====================================================================
    // helpers
    // =====================================================================
    // wait for pll_lock with a limit; returns the time from now in t_w
    real t_w;
    task wait_lock(input real limit, input [8*32-1:0] what);
        real t0;
        begin
            t0 = $realtime;
            fork : wl
                begin wait (pll_lock === 1'b1); disable wl; end
                begin #(limit); disable wl; end
            join
            t_w = $realtime - t0;
            if (pll_lock !== 1'b1) begin
                errors = errors + 1; $display("ERROR @%0t: %0s: no lock within %0.1f us", $time, what, limit / 1000.0);
            end
        end
    endtask

    task wait_unlock(input real limit, input [8*32-1:0] what);
        real t0;
        begin
            t0 = $realtime;
            fork : wu
                begin wait (pll_lock === 1'b0); disable wu; end
                begin #(limit); disable wu; end
            join
            t_w = $realtime - t0;
            if (pll_lock !== 1'b0) begin
                errors = errors + 1; $display("ERROR @%0t: %0s: lock not lost within %0.1f us", $time, what, limit / 1000.0);
            end
        end
    endtask

    task check_lol(input exp, input [8*32-1:0] what);
        begin
            if (lol !== exp) begin errors = errors + 1; $display("ERROR @%0t: lol = %b, expected %b (%0s)", $time, lol, exp, what); end
        end
    endtask

    task clear_lol;
        begin
            @(negedge clk_bit) lol_clr = 1'b1;
            @(negedge clk_bit) lol_clr = 1'b0;
        end
    endtask

    // full start: pll_en up, measure the lock time against the settling point
    task start_pll(input [8*32-1:0] what);
        real t0, t_set;
        begin
            @(posedge ref_clk);
            pll_en = 1'b1; t0 = $realtime;
            wait_lock(150000.0, what);
            t_set = t_notin - t0;
            $display("    %0s: inside +-0.08 %% after %0.1f us, lock after %0.1f us (window %0.2f us)",
                     what, t_set / 1000.0, t_w / 1000.0, W(0) / 1000.0);
            if (t_w > t_set + 5.0 * W(0) + 1000.0) begin
                errors = errors + 1; $display("ERROR: lock later than 5 windows after settling");
            end
        end
    endtask

    integer i, n0;
    real    t_s;

    initial begin
        $dumpfile("tb_usb_pll_lock_det.vcd");
        $dumpvars(0, tb_usb_pll_lock_det);

        // ---------------- [1] reset, refsel decode ----------------
        $display("[1] reset values, refsel decode");
        #1000;
        if (pll_lock || lol || clk60 || clk_on) begin errors = errors + 1; $display("ERROR: reset values"); end
        refsel = 2'b00; #1; if ((fb_div != 25) || refsel_err)  begin errors = errors + 1; $display("ERROR: refsel 00"); end
        refsel = 2'b01; #1; if ((fb_div != 20) || refsel_err)  begin errors = errors + 1; $display("ERROR: refsel 01"); end
        refsel = 2'b10; #1; if ((fb_div != 0)  || !refsel_err) begin errors = errors + 1; $display("ERROR: refsel 10"); end
        refsel = 2'b11; #1; if ((fb_div != 20) || !refsel_err) begin errors = errors + 1; $display("ERROR: refsel 11"); end
        refsel = 2'b01;
        rst_n = 1'b1;
        #2000;

        // ---------------- [2] lock acquisition ----------------
        $display("[2] lock acquisition, 24 MHz + 300 ppm");
        start_pll("24 MHz");
        if (t_w > 100000.0) begin errors = errors + 1; $display("ERROR: lock time > 100 us (spec 4.3)"); end
        n0 = n_pulse;
        #2000;
        if (!clk_on || (n_pulse - n0 < 20)) begin errors = errors + 1; $display("ERROR: CLKOUT did not start after lock"); end

        // ---------------- [3] CLKOUT stop / start ----------------
        $display("[3] CLKOUT stop / start at random phases");
        for (i = 0; i < 12; i = i + 1) begin
            #(50.0 + ({$random(seed)} % 20000) / 100.0);
            clk_susp = ~clk_susp;
        end
        clk_susp = 1'b0;
        #200;
        if (!clk_on) begin errors = errors + 1; $display("ERROR: CLKOUT not restarted"); end

        // ---------------- [4] small error ----------------
        $display("[4] +0.05 %% frequency error: lock kept");
        u_pll.f_off = 0.0005;
        #(6.0 * W(0));
        if (!pll_lock || lol) begin errors = errors + 1; $display("ERROR: lock lost at +0.05 %%"); end
        u_pll.f_off = 0.0;
        #(2.0 * W(0));

        // ---------------- [5] loss of lock ----------------
        $display("[5] +0.3 %% frequency error: loss of lock");
        u_pll.f_off = 0.003;
        wait_unlock(2.0 * W(0) + 200.0, "+0.3 %");
        $display("    lock lost after %0.1f us", t_w / 1000.0);
        #100;
        check_lol(1'b1, "after loss of lock");
        #500;
        if (clk_on) begin errors = errors + 1; $display("ERROR: CLKOUT still running without lock"); end
        u_pll.f_off = 0.0;
        wait_lock(6.0 * W(0), "relock");
        check_lol(1'b1, "sticky");
        clear_lol;
        check_lol(1'b0, "after lol_clr");

        // ---------------- [6] reference stops ----------------
        $display("[6] reference stops");
        #(3.0 * W(0));
        ref_run = 1'b0;
        wait_unlock(W(0) + 8192.0 * 2.5 + 1000.0, "reference stopped");
        $display("    lock lost after %0.1f us", t_w / 1000.0);
        #20000;
        ref_run = 1'b1;
        wait_lock(150000.0, "reference back");
        clear_lol;

        // ---------------- [7] dead clock ----------------
        $display("[7] clk_bit stops with pll_en = 1");
        #(2.0 * W(0));
        u_pll.dead = 1'b1;
        wait_unlock(2000.0, "dead clock");
        $display("    lock cleared %0.2f us after the clock stopped", t_w / 1000.0);
        #5000;
        u_pll.dead = 1'b0;
        #200;
        check_lol(1'b1, "clock back after a dead clock");
        wait_lock(150000.0, "after dead clock");
        clear_lol;

        // ---------------- [8] ordered switch-off ----------------
        $display("[8] ordered PLL switch-off and restart");
        #(2.0 * W(0));
        clk_susp = 1'b1;
        wait (clk_on === 1'b0);
        #20;
        pll_en = 1'b0;
        #1;
        if (pll_lock !== 1'b0) begin errors = errors + 1; $display("ERROR: lock not cleared by pll_en = 0"); end
        #5000;
        check_lol(1'b0, "ordered switch-off");
        if (clk60) begin errors = errors + 1; $display("ERROR: clk60 high with the PLL off"); end
        clk_susp = 1'b0;
        start_pll("restart");
        #100;
        check_lol(1'b0, "restart after an ordered switch-off");

        // ---------------- [9] 19.2 MHz, -500 ppm ----------------
        $display("[9] 19.2 MHz reference with refsel 00, then -500 ppm");
        clk_susp = 1'b1; wait (clk_on === 1'b0); #20; pll_en = 1'b0;
        f_ref = 19.2; refsel = 2'b00; ref_ppm = 0.0;
        #2000; clk_susp = 1'b0;
        start_pll("19.2 MHz");
        clk_susp = 1'b1; wait (clk_on === 1'b0); #20; pll_en = 1'b0;
        f_ref = 24.0; refsel = 2'b01; ref_ppm = -500.0;
        #2000; clk_susp = 1'b0;
        start_pll("24 MHz - 500 ppm");
        #100;
        check_lol(1'b0, "restarts in [9]");

        // ---------------- [10] wrong reference ----------------
        $display("[10] 26 MHz reference with refsel 01 (PLL at its VCO limit)");
        clk_susp = 1'b1; wait (clk_on === 1'b0); #20; pll_en = 1'b0;
        f_ref = 26.0; ref_ppm = 0.0;
        #2000; clk_susp = 1'b0;
        @(posedge ref_clk) pll_en = 1'b1;
        #150000;
        if (pll_lock) begin errors = errors + 1; $display("ERROR: lock with a wrong reference"); end
        else $display("    no lock (VCO at %0.1f MHz, ratio %0.3f instead of 20)", u_pll.f_now, u_pll.f_now / 26.0);

        $display("    CLKOUT pulses checked: %0d", n_pulse);
        errors = errors + ck_err + lk_err;
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #3000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
