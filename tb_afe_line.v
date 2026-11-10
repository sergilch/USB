//-----------------------------------------------------------------------------
// tb_afe_line.v - unit testbench for the line-level AFE models
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_line afe_line_bm.v afe_term_bm.v afe_hs_tx_bm.v \
//            afe_fsls_bm.v tb_afe_line.v
//   vvp sim_afe_line
//
// Set-up: a near end (our PHY: afe_hs_tx_bm, afe_fsls_bm, afe_term_bm) and a
// far end (host / device: the same three models) on one afe_line_bm.
//
// Checked (USB 2.0 levels, +-2 % unless noted)
//   [1] FS device attach: DP pull-up vs. host pull-downs -> DP 3.0 V, DM 0;
//       rxdp / rxrcv = J.  LS attach (DM pull-up) -> DM 3.0 V.
//   [2] Host drives SE0 (reset) with the device pull-up on -> DP 96 mV.
//   [3] Device chirp K: HS current into DM, host SE0 = 45 Ohm -> DM 798 mV.
//   [4] HS J / K with both ends terminated -> 400 mV (+-1 %); HS idle -> 0 V;
//       I_SCALE trim scales the amplitude.
//   [5] TX_EN settling: no current before T_EN, full current after; a short
//       TX_EN pulse never settles; TX_IN_P = TX_IN_N for longer than
//       T_SKEW_MAX counts a skew error, a shorter overlap does not.
//   [6] FS / LS driver: 10-90 % rise time 10 ns (FS) / 150 ns (LS) within
//       +-10 %, both inside the USB 2.0 ranges; drive J / K / SE0 levels.
//   [7] Receivers: single-ended thresholds with hysteresis, differential
//       receiver holds inside the +-100 mV window, rx_en = 0 values.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_afe_line;
    integer errors = 0;

    // near end
    reg  n_pu = 0, n_pu_m = 0, n_term = 0, n_pd_p = 0, n_pd_m = 0;
    reg  n_txp = 1, n_txn = 0, n_txen = 0;
    reg  n_oe = 0, n_dat = 1, n_se0 = 0, n_ls = 0, n_rxen = 1;
    // far end
    reg  f_pu = 0, f_term = 0, f_pd_p = 0, f_pd_m = 0;
    reg  f_txp = 1, f_txn = 0, f_txen = 0;
    reg  f_oe = 0, f_dat = 1, f_se0 = 0, f_ls = 0;

    wire [63:0] nt_dpg, nt_dpi, nt_dmg, nt_dmi, ft_dpg, ft_dpi, ft_dmg, ft_dmi;
    wire [63:0] nh_dpg, nh_dpi, nh_dmg, nh_dmi, fh_dpg, fh_dpi, fh_dmg, fh_dmi;
    wire [63:0] nf_dpg, nf_dpi, nf_dmg, nf_dmi, ff_dpg, ff_dpi, ff_dmg, ff_dmi;
    wire [63:0] dp_v, dm_v;
    wire        n_settled, f_settled;
    wire [31:0] n_skew, f_skew;
    wire        rxdp, rxdm, rxrcv, f_rxdp, f_rxdm, f_rxrcv;

    afe_term_bm  u_nt (.dp_pullup_en(n_pu), .dm_pullup_en(n_pu_m), .hs_term_en(n_term),
                       .dp_pulldown_en(n_pd_p), .dm_pulldown_en(n_pd_m),
                       .dp_g(nt_dpg), .dp_i(nt_dpi), .dm_g(nt_dmg), .dm_i(nt_dmi));
    afe_term_bm  u_ft (.dp_pullup_en(f_pu), .dm_pullup_en(1'b0), .hs_term_en(f_term),
                       .dp_pulldown_en(f_pd_p), .dm_pulldown_en(f_pd_m),
                       .dp_g(ft_dpg), .dp_i(ft_dpi), .dm_g(ft_dmg), .dm_i(ft_dmi));
    afe_hs_tx_bm u_nh (.TX_IN_P(n_txp), .TX_IN_N(n_txn), .TX_EN(n_txen),
                       .dp_g(nh_dpg), .dp_i(nh_dpi), .dm_g(nh_dmg), .dm_i(nh_dmi),
                       .settled(n_settled), .skew_err(n_skew));
    afe_hs_tx_bm u_fh (.TX_IN_P(f_txp), .TX_IN_N(f_txn), .TX_EN(f_txen),
                       .dp_g(fh_dpg), .dp_i(fh_dpi), .dm_g(fh_dmg), .dm_i(fh_dmi),
                       .settled(f_settled), .skew_err(f_skew));
    afe_fsls_bm  u_nf (.fs_oe(n_oe), .fs_dat(n_dat), .fs_se0(n_se0), .fs_ls(n_ls),
                       .dp_g(nf_dpg), .dp_i(nf_dpi), .dm_g(nf_dmg), .dm_i(nf_dmi),
                       .rx_en(n_rxen), .dp_v(dp_v), .dm_v(dm_v),
                       .rxdp(rxdp), .rxdm(rxdm), .rxrcv(rxrcv));
    afe_fsls_bm  u_ff (.fs_oe(f_oe), .fs_dat(f_dat), .fs_se0(f_se0), .fs_ls(f_ls),
                       .dp_g(ff_dpg), .dp_i(ff_dpi), .dm_g(ff_dmg), .dm_i(ff_dmi),
                       .rx_en(1'b1), .dp_v(dp_v), .dm_v(dm_v),
                       .rxdp(f_rxdp), .rxdm(f_rxdm), .rxrcv(f_rxrcv));
    afe_line_bm  u_line (
        .dp_g0(nt_dpg), .dp_i0(nt_dpi), .dp_g1(nh_dpg), .dp_i1(nh_dpi), .dp_g2(nf_dpg), .dp_i2(nf_dpi),
        .dp_g3(ft_dpg), .dp_i3(ft_dpi), .dp_g4(fh_dpg), .dp_i4(fh_dpi), .dp_g5(ff_dpg), .dp_i5(ff_dpi),
        .dm_g0(nt_dmg), .dm_i0(nt_dmi), .dm_g1(nh_dmg), .dm_i1(nh_dmi), .dm_g2(nf_dmg), .dm_i2(nf_dmi),
        .dm_g3(ft_dmg), .dm_i3(ft_dmi), .dm_g4(fh_dmg), .dm_i4(fh_dmi), .dm_g5(ff_dmg), .dm_i5(ff_dmi),
        .dp_v(dp_v), .dm_v(dm_v));

    real vp, vm;
    always @* begin vp = $bitstoreal(dp_v); vm = $bitstoreal(dm_v); end

    task chk_v(input [8*24-1:0] what, input real got, input real exp, input real tol);
        real d;
        begin
            d = got - exp; if (d < 0.0) d = -d;
            if (((exp == 0.0) && (d > 0.002)) || ((exp != 0.0) && (d > tol * ((exp < 0.0) ? -exp : exp)))) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s = %0.4f V, expected %0.4f V", $time, what, got, exp);
            end else
                $display("  %0s = %0.4f V (expected %0.4f V)", what, got, exp);
        end
    endtask

    task chk_b(input [8*24-1:0] what, input got, input exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s = %b, expected %b", $time, what, got, exp);
            end
        end
    endtask

    task all_off;
        begin
            n_pu = 0; n_pu_m = 0; n_term = 0; n_pd_p = 0; n_pd_m = 0; n_txen = 0; n_oe = 0;
            n_se0 = 0; n_ls = 0; n_dat = 1; n_rxen = 1;
            f_pu = 0; f_term = 0; f_pd_p = 0; f_pd_m = 0; f_txen = 0; f_oe = 0;
            f_se0 = 0; f_ls = 0; f_dat = 1;
            #400;
        end
    endtask

    // 10-90 % rise time of DP (0 -> VDD step of the near FS driver into a
    // host load: 15 kOhm pull-downs)
    task rise_time(input ls, input real exp);
        real t10, t90, tr, v_end;
        begin
            all_off;
            f_pd_p = 1; f_pd_m = 1;
            n_ls = ls; n_dat = ls;              // DM high (FS K / LS J): DP low
            n_oe = 1;
            #1000;
            v_end = 3.3 * 15000.0 / 15045.0;
            n_dat = !ls;                        // DP high
            t10 = -1.0; t90 = -1.0;
            while (t90 < 0.0) begin
                #0.1;
                if ((t10 < 0.0) && (vp >= 0.1 * v_end)) t10 = $realtime;
                if ((t90 < 0.0) && (vp >= 0.9 * v_end)) t90 = $realtime;
            end
            tr = t90 - t10;
            $display("  %0s 10-90 %% rise time = %0.1f ns (expected %0.1f ns)", ls ? "LS" : "FS", tr, exp);
            if ((tr < 0.9 * exp) || (tr > 1.1 * exp)) begin
                errors = errors + 1;
                $display("ERROR: rise time out of range");
            end
            if ( ls && ((tr < 75.0) || (tr > 300.0))) begin errors = errors + 1; $display("ERROR: LS outside USB 2.0 range"); end
            if (!ls && ((tr <  4.0) || (tr >  20.0))) begin errors = errors + 1; $display("ERROR: FS outside USB 2.0 range"); end
        end
    endtask

    reg [31:0] sk0;

    initial begin
        $dumpfile("tb_afe_line.vcd");
        $dumpvars(0, tb_afe_line);

        $display("[1] FS / LS attach");
        all_off;
        n_pu = 1; f_pd_p = 1; f_pd_m = 1; #10;
        chk_v("FS idle DP", vp, 3.3 * 15000.0 / 16500.0, 0.02);
        chk_v("FS idle DM", vm, 0.0, 0.02);
        #5; chk_b("rxdp (J)", rxdp, 1'b1); chk_b("rxdm (J)", rxdm, 1'b0); chk_b("rxrcv (J)", rxrcv, 1'b1);
        n_pu = 0; n_pu_m = 1; #10;
        chk_v("LS idle DM", vm, 3.3 * 15000.0 / 16500.0, 0.02);
        #5; chk_b("rxrcv (LS J)", rxrcv, 1'b0); chk_b("rxdm (LS J)", rxdm, 1'b1);

        $display("[2] Host SE0 (reset) against the device pull-up");
        all_off;
        n_pu = 1; f_pd_p = 1; f_pd_m = 1; f_oe = 1; f_se0 = 1; #100;
        chk_v("SE0 DP", vp, 3.3 * (1.0 / (1.0/45.0 + 1.0/15000.0)) / (1500.0 + 1.0 / (1.0/45.0 + 1.0/15000.0)), 0.02);
        chk_v("SE0 DM", vm, 0.0, 0.02);
        #5; chk_b("rxdp (SE0)", rxdp, 1'b0); chk_b("rxdm (SE0)", rxdm, 1'b0);

        $display("[3] Device chirp K (host drives SE0)");
        n_txp = 0; n_txn = 1; n_txen = 1; #50;
        chk_v("chirp K DM", vm, 17.78e-3 / (1.0/45.0 + 1.0/15000.0), 0.02);
        chk_v("chirp K DP", vp, 3.3 * (1.0 / (1.0/45.0 + 1.0/15000.0)) / (1500.0 + 1.0 / (1.0/45.0 + 1.0/15000.0)), 0.02);

        $display("[4] HS signalling, both ends terminated");
        all_off;
        n_term = 1; f_term = 1;
        n_txp = 1; n_txn = 0; n_txen = 1; #50;
        chk_v("HS J DP", vp, 0.400, 0.01);
        chk_v("HS J DM", vm, 0.0, 0.01);
        n_txp = 0; n_txn = 1; #2;
        chk_v("HS K DM", vm, 0.400, 0.01);
        chk_v("HS K DP", vp, 0.0, 0.01);
        u_nh.i_scale = 1.1; #1;
        chk_v("HS K DM, trim +10 %", vm, 0.440, 0.01);
        u_nh.i_scale = 1.0;
        n_txen = 0; #1;
        chk_v("HS idle DP", vp, 0.0, 0.01);
        chk_v("HS idle DM", vm, 0.0, 0.01);

        $display("[5] TX_EN settling, P/N skew");
        n_txp = 1; n_txn = 0;
        n_txen = 1; #19;
        chk_v("DP 19 ns after TX_EN", vp, 0.0, 0.01);
        #2;
        chk_v("DP 21 ns after TX_EN", vp, 0.400, 0.01);
        n_txen = 0; #5; n_txen = 1; #10; n_txen = 0; #5; n_txen = 1; #15;
        chk_b("settled after retrigger (15 ns)", n_settled, 1'b0);
        #6;
        chk_b("settled 21 ns after last rise", n_settled, 1'b1);
        sk0 = n_skew;
        n_txp = 0; #0.05; n_txn = 1; #5;           // 50 ps overlap: tolerated
        if (n_skew != sk0) begin errors = errors + 1; $display("ERROR: 50 ps P = N counted as skew"); end
        n_txn = 0; #0.3; n_txp = 1; #5;            // 300 ps overlap: error
        if (n_skew != sk0 + 1) begin errors = errors + 1; $display("ERROR: 300 ps P = N not counted (%0d)", n_skew - sk0); end
        else $display("  skew detection ok (50 ps ignored, 300 ps counted)");

        $display("[6] FS / LS driver");
        rise_time(1'b0, 10.0);
        rise_time(1'b1, 150.0);
        all_off;
        f_pd_p = 1; f_pd_m = 1; n_oe = 1; n_dat = 1; n_ls = 0; #100;
        chk_v("FS drive J DP", vp, 3.3 * 15000.0 / 15045.0, 0.02);
        n_dat = 0; #100;
        chk_v("FS drive K DM", vm, 3.3 * 15000.0 / 15045.0, 0.02);
        n_se0 = 1; #100;
        chk_v("FS drive SE0 DP", vp, 0.0, 0.02);
        chk_v("FS drive SE0 DM", vm, 0.0, 0.02);

        $display("[7] Receivers");
        all_off;
        n_term = 1; n_txen = 1; n_txp = 1; n_txn = 0; #50;   // DP 0.8 V (single 45 Ohm)
        #5; chk_b("rxdp at 0.8 V", rxdp, 1'b0); chk_b("rxrcv at +0.8 V", rxrcv, 1'b1);
        u_nh.i_scale = 0.2; #5;                              // +160 mV: still 1
        chk_b("rxrcv at +160 mV", rxrcv, 1'b1);
        n_txp = 0; n_txn = 1; #5;                            // -160 mV
        chk_b("rxrcv at -160 mV", rxrcv, 1'b0);
        u_nh.i_scale = 0.05; n_txp = 1; n_txn = 0; #5;       // +40 mV: holds 0
        chk_b("rxrcv holds at +40 mV", rxrcv, 1'b0);
        u_nh.i_scale = 1.0;
        n_rxen = 0; #5;
        chk_b("rxdp, rx_en = 0", rxdp, 1'b0); chk_b("rxdm, rx_en = 0", rxdm, 1'b0); chk_b("rxrcv, rx_en = 0", rxrcv, 1'b1);
        n_rxen = 1;
        all_off;
        f_oe = 1; f_dat = 1; n_term = 0;                     // far drives 3.3 V on DP into nothing
        #100;
        chk_b("rxdp at 3.3 V", rxdp, 1'b1);
        chk_v("undriven DM (leak)", vm, 0.0, 0.02);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
