//-----------------------------------------------------------------------------
// ams_pwr_seq.vh - stimulus and checks of the power-up / PLL test; included in
//                  the body of the top module
//
// Included by AFE/ams/tb_ams_pwr.vams (Spectre AMS: afe_ldo x 2, afe_pll) and
// tb_ams_pwr_shadow.v (Icarus: afe_pll_bm, LDOs as delays).  The including
// module provides
//   reg  vin_on, pwr_good, susp_req, clk_susp, wake     stimulus
//   wire por_n, pg18a, clk_bit, ref_clk, clk60, ce60, clk_on, pll_lock, lol,
//        bias_en, ldo_en, pll_en, iso_en, core_rst_n_b, iso_en_b, afe_en_b,
//        dir_hold_b, clk_en_b, pll_err, state[3:0]     from the DUT chain
//   `AMS_V18A                                          VDD18A in volts
//   localparam real VIN_RAMP                           VDD33 ramp time, ns
//
// Sequence (times are measured and printed; limits are the spec's)
//   1. VDD33 ramps up (vin_on); pwr_good once it is complete.  The digital
//      LDO's POR_N releases por_n; the sequencer turns on LDO_EN; the analog
//      LDO's PWR_GOOD gives pg18a and VDD18A must then be 1.75-1.85 V.
//   2. Sequencer: bias, pll_en, lock within 100 us of pll_en (spec 4.3),
//      iso_en 0, core reset released, CLKOUT, DIR released (state RUN; the
//      clk_bit-side copies are checked 100 ns later).
//      CLKOUT 60 MHz +- 0.1 % over 64 periods, 50 % duty (4 + 4 clk_bit).
//   3. Low power with CLKOUT stopped: CLKOUT stops low, then pll_en = 0; no
//      CLKOUT edge for 5 us.  Wake: relock, CLKOUT within 100 us, RUN.
//   Throughout: pll_en rises only after bias_en has been on for BIAS_CYC
//   reference cycles; iso_en falls only with pll_lock; no CLKOUT edge with
//   pll_en = 0; pll_err stays 0.
//-----------------------------------------------------------------------------
    localparam BIAS_CYC = 240;
    localparam real T_REF = 41.6666667;

    integer errors = 0;

    // ---------------- continuous checks ----------------
    real t_bias = -1.0, t_ck = -1.0e9;
    always @(posedge bias_en) t_bias = $realtime;
    always @(posedge pll_en)
        if (t_bias < 0.0 || $realtime - t_bias < BIAS_CYC * T_REF - 1.0) begin
            errors = errors + 1; $display("ERROR @%0t: pll_en before the bias settling time", $time);
        end
    always @(negedge iso_en)
        if (pll_lock !== 1'b1) begin errors = errors + 1; $display("ERROR @%0t: iso_en released without lock", $time); end
    always @(posedge clk60) begin
        t_ck = $realtime;
        if (pll_en !== 1'b1) begin errors = errors + 1; $display("ERROR @%0t: CLKOUT edge with pll_en = 0", $time); end
    end
    always @(posedge pll_err) begin errors = errors + 1; $display("ERROR @%0t: pll_err (lock timeout)", $time); end

    integer hi_n = 0;
    always @(posedge clk_bit) if (clk60) hi_n = hi_n + 1;
    always @(negedge clk60) begin
        if (t_ck > 0.0 && hi_n != 4) begin errors = errors + 1; $display("ERROR @%0t: CLKOUT high for %0d clk_bit cycles", $time, hi_n); end
        hi_n = 0;
    end

    // ---------------- sequence ----------------
    real t0, t_por, t_pg, t_pll, t_lock, t_run, t_a, t_b, f, v;
    integer k;
    initial begin
        $display("1. supplies");
        #(1000);
        vin_on = 1'b1; t0 = $realtime;
        #(VIN_RAMP + 1000.0);
        pwr_good = 1'b1;
        wait (por_n === 1'b1); t_por = $realtime;
        wait (pg18a === 1'b1); t_pg = $realtime;
        v = `AMS_V18A;
        $display("   VDD33 on -> POR_N %.1f us, -> PG18A %.1f us, VDD18A %.3f V",
                 (t_por - t0) / 1000.0, (t_pg - t0) / 1000.0, v);
        if (v < 1.75 || v > 1.85) begin errors = errors + 1; $display("ERROR: VDD18A %.3f V at PG18A", v); end
        if (ldo_en !== 1'b1) begin errors = errors + 1; $display("ERROR: LDO_EN not on after POR"); end

        $display("2. power-up sequence");
        wait (pll_en === 1'b1);   t_pll  = $realtime;
        wait (pll_lock === 1'b1); t_lock = $realtime;
        wait (state === 4'd5);    t_run  = $realtime;
        #(100);                                   // clk_bit-side copies: 2 edges
        $display("   PG18A -> pll_en %.1f us, pll_en -> lock %.1f us, lock -> RUN %.2f us",
                 (t_pll - t_pg) / 1000.0, (t_lock - t_pll) / 1000.0, (t_run - t_lock) / 1000.0);
        if (t_lock - t_pll > 100000.0) begin errors = errors + 1; $display("ERROR: lock later than 100 us after pll_en"); end
        if (iso_en !== 1'b0 || core_rst_n_b !== 1'b1 || dir_hold_b !== 1'b0) begin
            errors = errors + 1; $display("ERROR: RUN without iso_en 0 / reset release / DIR release");
        end
        @(posedge clk60); t_a = $realtime;
        for (k = 0; k < 64; k = k + 1) @(posedge clk60);
        t_b = $realtime;
        f = 64.0e3 / (t_b - t_a);
        $display("   CLKOUT %.4f MHz", f);
        if (f < 59.94 || f > 60.06) begin errors = errors + 1; $display("ERROR: CLKOUT not 60 MHz +- 0.1 %%"); end

        $display("3. low power with CLKOUT stopped, wake");
        clk_susp = 1'b1; susp_req = 1'b1;
        wait (pll_en === 1'b0);
        if (clk60 !== 1'b0) begin errors = errors + 1; $display("ERROR: pll_en fell with CLKOUT high"); end
        #(5000);
        if ($realtime - t_ck < 5000.0) begin errors = errors + 1; $display("ERROR: CLKOUT edges in low power"); end
        t_a = $realtime;
        wake = 1'b1; susp_req = 1'b0; #(200); wake = 1'b0;
        wait (state === 4'd5);
        @(posedge clk60);
        $display("   wake -> CLKOUT %.1f us", ($realtime - t_a) / 1000.0);
        if ($realtime - t_a > 100000.0) begin errors = errors + 1; $display("ERROR: CLKOUT later than 100 us after wake"); end
        clk_susp = 1'b0;
        #(2000);

        $display("--------------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #(1500000);
        $display("TEST FAILED: timeout");
        $finish;
    end
