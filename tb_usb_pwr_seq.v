//-----------------------------------------------------------------------------
// tb_usb_pwr_seq.v - power-up / suspend / failure sequencing with the PLL model
//                    and the AFE boundary blocks (phase A7)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_pwr_seq usb_pwr_seq.v usb_pll_lock_det.v usb_clk_gen.v \
//            usb_afe_tx_if.v usb_afe_rx_if.v usb_mode_term_ctrl.v usb_rx_status_flt.v \
//            usb_rx_status_sync.v afe_pll_bm.v tb_usb_pwr_seq.v
//   vvp sim_pwr_seq
//
// Setup: supplies (VDD33 -> pwr_good, VDD18A -> pg18a and the reference clock),
//   ref_clk 24 MHz + 200 ppm -> afe_pll_bm (TAU 5 us) -> clk_bit ->
//   usb_pll_lock_det + usb_clk_gen (clk_en = clk_en_b) and usb_pwr_seq.  On the
//   clk_bit side, reset by core_rst_n_b and isolated by iso_en_b:
//   usb_afe_tx_if, usb_afe_rx_if (rx_en = afe_en_b, HS), usb_mode_term_ctrl (FS
//   peripheral: pull-up on), usb_rx_status_sync.  An isolation-cell model on the
//   AFE side clamps every digital output to its isolated value while the iso_en
//   pin is 1.  While VDD33 is off (from 200 ns after pwr_good falls until it
//   rises) every AFE output to the digital is X.
//
// Checked all the time
//   * no boundary signal is X / Z after power-on reset, in either direction:
//     the AFE pins behind the isolation cells, the digital outputs whenever the
//     iso_en pin is 0, and every digital output that takes AFE inputs
//     (usb_afe_rx_if, usb_rx_status_sync);
//   * iso_en_b = 1 whenever the iso_en pin is 1 (asynchronous, no clock needed);
//   * pll_en rises only with bias_en on for >= BIAS_CYC; iso_en falls, the core
//     reset is released and CLKOUT starts only with the PLL locked;
//   * pll_en is never off for less than OFF_CYC reference cycles;
//   * CLKOUT: no edge while pll_en = 0, every high phase exactly 4 clk_bit
//     cycles; pll_en falls (other than on a supply loss) only with CLKOUT low
//     and clk_on = 0;
//   * dir_hold_b is 1 whenever CLKOUT has not run for 30 ns while the core is
//     out of reset, and falls only while CLKOUT is running;
//   * afe_en_b (RX_EN / CDR_EN) is 0 while CLKOUT is stopped.
// Cases
//   [1] POR with no supplies, VDD18A (reference) only: everything stays off
//   [2] power-up: order and times (bias, PLL lock, release, CLKOUT, DIR)
//   [3] low power with CLKOUT running (ClockSuspendM = 1): PLL and CLKOUT on,
//       RX_EN off; wake
//   [4] low power with CLKOUT stopped: CLKOUT stops low, then the PLL; the core
//       and the terminations stay alive; wake: relock, CLKOUT, DIR released
//   [5] loss of lock while running (+0.3 %): CLKOUT stops, DIR held, relock
//       after the error is gone; the lock detector's lol is set
//   [6] supply loss while transmitting: isolated at once, back through OFF;
//       power-up with a dead PLL: lock timeout, pll_err, retry, lock
//   [7] supply loss in low power (clk_bit stopped): isolated without a clock;
//       VDD18A off too; full power-up again
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_pwr_seq;
    localparam BIAS_CYC = 240, LOCK_TO = 4800, OFF_CYC = 24;
    localparam real T_REF = 1000.0 / (24.0 * 1.0002);

    integer errors = 0;

    // ---------------- supplies, reference ----------------
    reg por_n = 1'bx, vdd33 = 1'b0, vdd18a = 1'b0;
    reg pwr_good = 1'b0, pg18a = 1'b0;
    reg ref_clk = 1'b0;
    always begin
        #(T_REF / 2.0);
        ref_clk = vdd18a ? ~ref_clk : 1'b0;
    end
    reg afe_ok = 1'b0;                                  // AFE outputs valid
    always @(pwr_good) begin
        if (pwr_good) afe_ok = 1'b1;
        else begin #200; if (!pwr_good) afe_ok = 1'b0; end
    end

    // ---------------- DUT chain ----------------
    wire clk_bit, pll_lock, lol, refsel_err, ce60, clk60, clk_on;
    wire [4:0] fb_div;
    wire bias_en, ldo_en, pll_en, iso_en, core_rst_n_b, iso_en_b, afe_en_b, dir_hold_b, clk_en_b, pll_err;
    wire [3:0] state;
    reg  susp_req = 1'b0, clk_susp = 1'b0, wake = 1'b0;

    afe_pll_bm u_pll (.CDR_FREF(ref_clk), .PLL_EN(pll_en), .clk_out(clk_bit));
    usb_pll_lock_det u_ld (.clk_bit(clk_bit), .ref_clk(ref_clk), .rst_n(por_n), .pll_en(pll_en),
                           .refsel(2'b01), .lol_clr(1'b0), .pll_lock(pll_lock), .lol(lol),
                           .fb_div(fb_div), .refsel_err(refsel_err));
    usb_clk_gen u_cg (.clk_bit(clk_bit), .rst_n(por_n), .clk_en(clk_en_b),
                      .ce60(ce60), .clk60(clk60), .clk_on(clk_on));
    usb_pwr_seq #(.BIAS_CYC(BIAS_CYC), .LOCK_TO(LOCK_TO), .OFF_CYC(OFF_CYC)) dut (
        .ref_clk(ref_clk), .clk_bit(clk_bit), .por_n(por_n),
        .pwr_good(pwr_good), .pg18a(pg18a), .pll_lock(pll_lock), .clk_on(clk_on),
        .susp_req(susp_req), .clk_susp(clk_susp), .wake(wake),
        .bias_en(bias_en), .ldo_en(ldo_en), .pll_en(pll_en), .iso_en(iso_en),
        .core_rst_n_b(core_rst_n_b), .iso_en_b(iso_en_b), .afe_en_b(afe_en_b),
        .dir_hold_b(dir_hold_b), .clk_en_b(clk_en_b), .state(state), .pll_err(pll_err));

    // TX: idle, or a stream of HS packets while tx_on
    reg tx_on = 1'b0, txd = 1'b1, tx_en = 1'b0;
    always @(posedge clk_bit) begin
        if (tx_on && core_rst_n_b) begin
            tx_en <= ({$random} % 64) != 0 || tx_en;
            txd   <= $random;
            if (({$random} % 200) == 0) tx_en <= 1'b0;
        end else begin
            tx_en <= 1'b0; txd <= 1'b1;
        end
    end
    wire hs_tx_p, hs_tx_n, hs_tx_en, fs_oe, fs_dat, fs_se0, fs_ls, tx_active;
    usb_afe_tx_if u_tx (.clk_bit(clk_bit), .rst_n(core_rst_n_b), .txd(txd), .tx_en(tx_en),
        .tx_se0(1'b0), .tx_speed(2'b00), .tx_lead(5'd10), .tx_lag(3'd0), .drv_dis(1'b0),
        .iso_en(iso_en_b), .lead_first(1'b0),
        .hs_tx_p(hs_tx_p), .hs_tx_n(hs_tx_n), .hs_tx_en(hs_tx_en), .fs_oe(fs_oe), .fs_dat(fs_dat),
        .fs_se0(fs_se0), .fs_ls(fs_ls), .tx_active(tx_active));

    // AFE outputs to the digital (X while VDD33 is off)
    wire a_sq   = afe_ok ? 1'b1 : 1'bx;
    wire a_rxd  = afe_ok ? 1'b1 : 1'bx;
    wire a_dp   = afe_ok ? 1'b1 : 1'bx;
    wire a_dm   = afe_ok ? 1'b0 : 1'bx;
    wire a_rcv  = afe_ok ? 1'b1 : 1'bx;
    wire a_disc = afe_ok ? 1'b0 : 1'bx;
    wire a_vb   = afe_ok ? 1'b1 : 1'bx;
    wire a_se   = afe_ok ? 1'b0 : 1'bx;
    wire rx_en_hs, cdr_en, hs_rxd, hs_squelch, hs_cdr_lock;
    wire clk_rx = clk_bit & (cdr_en === 1'b1);
    usb_afe_rx_if u_rx (.clk_bit(clk_bit), .rst_n(core_rst_n_b), .speed(2'b00), .rx_en(afe_en_b),
        .iso_en(iso_en_b), .lock_dly(3'd2), .sq_comp(3'd0), .rx_en_hs(rx_en_hs), .cdr_en(cdr_en),
        .clk_rx(clk_rx), .hs_rxd_a(a_rxd), .squelch_a(a_sq),
        .hs_rxd(hs_rxd), .hs_squelch(hs_squelch), .hs_cdr_lock(hs_cdr_lock));

    wire pu_dp, pu_dm, hst, pd_dp, pd_dm, tbusy, byp, sdis, edis, ddis, hostm;
    usb_mode_term_ctrl u_mode (.clk_bit(clk_bit), .rst_n(core_rst_n_b), .ce60(ce60),
        .xcvrselect(2'b01), .termselect(1'b1), .opmode(2'b00), .dp_pulldown(1'b0), .dm_pulldown(1'b0),
        .iso_en(iso_en_b), .dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(hst),
        .dp_pulldown_en(pd_dp), .dm_pulldown_en(pd_dm), .term_busy(tbusy), .tx_bypass(byp),
        .tx_sync_dis(sdis), .tx_eop_dis(edis), .drv_dis(ddis), .host_mode(hostm));

    wire s_dp, s_dm, s_rcv, s_sq, s_disc, s_vv, s_sv, s_se, s_id;
    usb_rx_status_sync u_ss (.clk_bit(clk_bit), .rst_n(core_rst_n_b), .ce60(ce60),
        .rxdp(a_dp), .rxdm(a_dm), .rxrcv(a_rcv), .squelch(a_sq), .disc(a_disc),
        .a_vbus_vld(a_vb), .sess_vld(a_vb), .sess_end(a_se), .id_gnd(a_se),
        .sq_flt(4'd2), .disc_flt(4'd2), .vb_flt(16'd4),
        .rxdp_s(s_dp), .rxdm_s(s_dm), .rxrcv_s(s_rcv), .squelch_s(s_sq), .disc_s(s_disc),
        .a_vbus_vld_s(s_vv), .sess_vld_s(s_sv), .sess_end_s(s_se), .id_gnd_s(s_id));

    initial begin
        $dumpfile("tb_usb_pwr_seq.vcd");
        $dumpvars(0, tb_usb_pwr_seq);
    end

    // ---------------- isolation-cell model, boundary vectors ----------------
    //                 hs_tx_p n en fs_oe dat se0 ls  rx_en_hs cdr_en  pu_dp pu_dm hst pd_dp pd_dm
    wire [13:0] dig_out = {hs_tx_p, hs_tx_n, hs_tx_en, fs_oe, fs_dat, fs_se0, fs_ls, rx_en_hs, cdr_en,
                           pu_dp, pu_dm, hst, pd_dp, pd_dm};
    localparam [13:0] ISO = 14'b10_0_0100_00_00000;
    wire [13:0] afe_pin = iso_en ? ISO : dig_out;
    wire [3:0]  pwr_pin = {bias_en, ldo_en, pll_en, iso_en};
    wire [11:0] dig_in  = {hs_rxd, hs_squelch, hs_cdr_lock, s_dp, s_dm, s_rcv, s_sq, s_disc, s_vv, s_sv, s_se, s_id};
    wire [5:0]  dig_ctl = {core_rst_n_b, iso_en_b, afe_en_b, dir_hold_b, clk_en_b, pll_err};

    // ---------------- continuous checks ----------------
    real    t_bias_on = -1.0, t_clk60 = -1.0e9, t_lock_fall = -1.0e9, t_pg_fall = -1.0e9;
    real    t_clk60_r;
    integer clk60_edges = 0, n_err_max = 0;
    reg     chk_on = 1'b0;

    task err(input [8*72-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 40) $display("ERROR @%0t: %0s (state %0d)", $time, msg, state);
        end
    endtask

    always @(posedge bias_en) t_bias_on = $realtime;
    always @(negedge bias_en) t_bias_on = -1.0;
    always @(negedge pll_lock) t_lock_fall = $realtime;
    always @(negedge pwr_good or negedge pg18a) t_pg_fall = $realtime;

    real t_pll_fall = -1.0e9;
    always @(negedge pll_en) t_pll_fall = $realtime;
    always @(posedge pll_en) if (chk_on && t_pll_fall > 0.0 && $realtime - t_pll_fall < OFF_CYC * T_REF - 1.0)
        err("PLL off for less than OFF_CYC reference cycles");
    always @(posedge pll_en) if (chk_on) begin
        if (t_bias_on < 0.0 || $realtime - t_bias_on < BIAS_CYC * T_REF - 1.0)
            err("pll_en rose before the bias settling time");
    end
    real t_pg18_fall = -1.0e9;
    always @(negedge pg18a) t_pg18_fall = $realtime;
    always @(negedge pll_en) if (chk_on && $realtime - t_pg18_fall > 200.0) begin
        if (clk60 !== 1'b0 || clk_on !== 1'b0) err("pll_en fell with CLKOUT running");
    end
    always @(negedge iso_en) if (chk_on && pll_lock !== 1'b1) err("iso_en released without PLL lock");
    always @(posedge core_rst_n_b) if (chk_on && pll_lock !== 1'b1) err("core reset released without PLL lock");
    always @(posedge clk60) begin
        clk60_edges = clk60_edges + 1; t_clk60 = $realtime; t_clk60_r = $realtime;
        if (chk_on && pll_en !== 1'b1) err("CLKOUT edge with pll_en = 0");
        if (chk_on && pll_lock !== 1'b1 && $realtime - t_lock_fall > 300.0) err("CLKOUT running without lock");
    end
    integer hi_cyc = 0;
    always @(posedge clk_bit) begin
        if (clk60) hi_cyc = hi_cyc + 1;
    end
    always @(negedge clk60) begin
        if (chk_on && hi_cyc != 4 && $realtime - t_pg_fall > 300.0) err("CLKOUT high phase not 4 clk_bit cycles");
        hi_cyc = 0;
    end
    always @(negedge dir_hold_b) if (chk_on && $realtime - t_clk60 > 20.0) err("DIR hold released with CLKOUT stopped");

    // sampled checks every 2 ns
    always #2 if (chk_on) begin
        if (^afe_pin === 1'bx) err("AFE pin X / Z behind the isolation cells");
        if (^pwr_pin === 1'bx) err("power pin X / Z");
        if (!iso_en && (^dig_out === 1'bx)) err("digital output X / Z while not isolated");
        if (^dig_in === 1'bx) err("digital input-side output X / Z");
        if (^dig_ctl === 1'bx || ^state === 1'bx) err("sequencer output X / Z");
        if (iso_en === 1'b1 && iso_en_b !== 1'b1) err("iso_en_b not set with the iso_en pin");
        if (core_rst_n_b && dir_hold_b !== 1'b1 && $realtime - t_clk60 > 30.0) err("CLKOUT stopped, DIR not held");
        if (afe_en_b && $realtime - t_clk60 > 30.0 && $realtime - t_pg_fall > 300.0) err("RX_EN allowed with CLKOUT stopped");
    end

    // ---------------- helpers ----------------
    task wait_ns(input real t); begin #(t); end endtask
    task wait_state(input [3:0] s, input real tmax, input [8*40-1:0] what);
        real t0;
        begin
            t0 = $realtime;
            while (state !== s && $realtime - t0 < tmax) #10;
            if (state !== s) err({"state not reached: ", what});
        end
    endtask
    task expect_off(input [8*40-1:0] what);
        begin
            if (pwr_pin !== {1'b0, por_n, 1'b0, 1'b1} || afe_pin !== ISO || core_rst_n_b !== 1'b0 || iso_en_b !== 1'b1 ||
                dir_hold_b !== 1'b1 || afe_en_b !== 1'b0 || clk60 !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: not all off (pins %b, afe %b, rst %b iso %b dir %b afe_en %b)",
                         $time, what, pwr_pin, afe_pin, core_rst_n_b, iso_en_b, dir_hold_b, afe_en_b);
            end
        end
    endtask
    task supplies_up;
        begin
            vdd18a = 1'b1; #500 pg18a = 1'b1;
            #1000 vdd33 = 1'b1; #500 pwr_good = 1'b1;
        end
    endtask

    real t0, t_pll, t_iso, t_rel, t_ck, t_dir, t_afe, t_lock;
    integer e0;
    initial begin
        // [1] POR, no supplies
        #1 por_n = 1'b0;
        #5;
        chk_on = 1'b1;
        expect_off("POR");
        #100 por_n = 1'b1;
        #2000;
        expect_off("POR released, no supplies");
        $display("[1] POR without supplies, VDD18A only");
        vdd18a = 1'b1; #500 pg18a = 1'b1;
        #20000;
        if (state !== 4'd0) err("left OFF without pwr_good");
        expect_off("VDD18A only");

        // [2] power-up
        $display("[2] power-up");
        vdd33 = 1'b1; #300 pwr_good = 1'b1;
        t0 = $realtime;
        wait (pll_en === 1'b1); t_pll = $realtime;
        wait (pll_lock === 1'b1); t_lock = $realtime;
        wait (iso_en === 1'b0); t_iso = $realtime;
        wait (core_rst_n_b === 1'b1); t_rel = $realtime;
        wait (clk60 === 1'b1); t_ck = $realtime;
        wait (dir_hold_b === 1'b0); t_dir = $realtime;
        wait (afe_en_b === 1'b1); t_afe = $realtime;
        $display("   pwr_good -> pll_en %.2f us, -> lock %.2f us, -> iso_en 0 %.2f us, -> core out of reset %.2f us,",
                 (t_pll - t0) / 1000.0, (t_lock - t0) / 1000.0, (t_iso - t0) / 1000.0, (t_rel - t0) / 1000.0);
        $display("   -> CLKOUT %.2f us, -> DIR released %.2f us, -> RX_EN allowed %.2f us",
                 (t_ck - t0) / 1000.0, (t_dir - t0) / 1000.0, (t_afe - t0) / 1000.0);
        if (t_pll - t0 > (BIAS_CYC + 6) * T_REF) err("bias phase too long");
        if (t_lock - t_pll > 100000.0) err("PLL lock later than 100 us after pll_en (spec 4.3)");
        if (t_iso - t_lock > 5 * T_REF || t_iso < t_lock) err("iso_en not released 2-5 reference cycles after lock");
        if (t_dir - t_ck > 6 * T_REF) err("DIR released too long after CLKOUT started");
        #2000;
        if (state !== 4'd5) err("not in RUN after power-up");
        if (rx_en_hs !== 1'b1 || cdr_en !== 1'b1) err("RX_EN / CDR_EN not on in HS RUN");
        if (pu_dp !== 1'b1) err("pull-up not on after power-up (FS peripheral)");
        if (pll_err !== 1'b0) err("pll_err after a good power-up");

        // [3] low power, CLKOUT running
        $display("[3] low power with CLKOUT running");
        tx_on = 1'b1; #3000; tx_on = 1'b0; #2000;
        susp_req = 1'b1;
        wait_state(4'd6, 1000.0, "SUSPC");
        #500;
        if (rx_en_hs !== 1'b0 || cdr_en !== 1'b0) err("RX_EN / CDR_EN still on in low power");
        if (pll_en !== 1'b1 || $realtime - t_clk60 > 30.0) err("PLL / CLKOUT stopped although ClockSuspendM = 1");
        #5000;
        wake = 1'b1; #200 susp_req = 1'b0; #100 wake = 1'b0;
        wait_state(4'd5, 1000.0, "RUN after SUSPC");
        #500;
        if (rx_en_hs !== 1'b1) err("RX_EN not back after wake");

        // [4] low power, CLKOUT stopped
        $display("[4] low power with CLKOUT and PLL stopped");
        clk_susp = 1'b1; susp_req = 1'b1;
        e0 = clk60_edges;
        wait_state(4'd8, 2000.0, "SUSP");
        if (pll_en !== 1'b0) err("PLL not off in SUSP");
        #3000;
        if (clk60_edges - e0 > 20) err("CLKOUT ran too long after the suspend request");
        e0 = clk60_edges;
        #20000;
        if (clk60_edges != e0) err("CLKOUT edges in SUSP");
        if (core_rst_n_b !== 1'b1 || iso_en_b !== 1'b0 || pu_dp !== 1'b1 || bias_en !== 1'b1)
            err("core / terminations / bias not kept alive in SUSP");
        if (s_dp !== 1'b1 || s_rcv !== 1'b1) err("FS receiver status lost in SUSP");
        t0 = $realtime;
        wake = 1'b1; #200 susp_req = 1'b0; #100 wake = 1'b0;
        wait (clk60 === 1'b1); t_ck = $realtime;
        wait_state(4'd5, 5000.0, "RUN after SUSP");
        $display("   wake -> CLKOUT %.2f us (relock)", (t_ck - t0) / 1000.0);
        if (t_ck - t0 > 100000.0) err("CLKOUT later than 100 us after wake");
        clk_susp = 1'b0;
        #2000;

        // [5] loss of lock while running
        $display("[5] loss of lock while running (+0.3 %%)");
        u_pll.f_off = 0.003;
        wait_state(4'd7, 40000.0, "CSTOP after loss of lock");
        wait (pll_en === 1'b0);
        #30000;
        if (state === 4'd5) err("back in RUN with the PLL off frequency");
        u_pll.f_off = 0.0;
        wait_state(4'd5, 300000.0, "RUN after relock");
        if (lol !== 1'b1) err("lol not set after a loss of lock");
        if (core_rst_n_b !== 1'b1) err("core reset during a relock");
        #2000;

        // [6] supply loss while transmitting; dead PLL at power-up
        $display("[6] supply loss while transmitting, then power-up with a dead PLL");
        tx_on = 1'b1; #1500;
        if (hs_tx_en !== 1'b1 && tx_active !== 1'b1) $display("   (TX not active at the supply loss)");
        pwr_good = 1'b0; vdd33 = 1'b0;
        #(3 * T_REF + 5);
        if (iso_en !== 1'b1 || afe_pin !== ISO) err("not isolated 3 reference cycles after the supply loss");
        #2000;
        tx_on = 1'b0;
        expect_off("after the supply loss");
        u_pll.dead = 1'b1;
        #5000 vdd33 = 1'b1; #300 pwr_good = 1'b1;
        wait (pll_err === 1'b1);
        $display("   pll_err after %.1f us", ($realtime - t_pg_fall) / 1000.0);
        wait (pll_en === 1'b0); t0 = $realtime;
        wait (pll_en === 1'b1);
        if ($realtime - t0 < OFF_CYC * T_REF - 1.0) err("PLL off time before the retry too short");
        if (iso_en !== 1'b1 || core_rst_n_b !== 1'b0 || dir_hold_b !== 1'b1 || clk60 !== 1'b0 || afe_pin !== ISO)
            err("lock timeout: not isolated / in reset");
        u_pll.dead = 1'b0;
        wait_state(4'd5, 400000.0, "RUN after the retry");
        if (pll_err !== 1'b1) err("pll_err not sticky");
        #2000;

        // [7] supply loss in low power without clk_bit
        $display("[7] supply loss in low power (clk_bit stopped)");
        clk_susp = 1'b1; susp_req = 1'b1;
        wait_state(4'd8, 2000.0, "SUSP");
        #2000;
        pwr_good = 1'b0; vdd33 = 1'b0;
        #(3 * T_REF + 5);
        if (iso_en !== 1'b1 || iso_en_b !== 1'b1 || core_rst_n_b !== 1'b0 || afe_pin !== ISO)
            err("not isolated / reset without clk_bit");
        #1000 pg18a = 1'b0; vdd18a = 1'b0;
        #10000;
        expect_off("all supplies off");
        clk_susp = 1'b0; susp_req = 1'b0;
        supplies_up;
        wait_state(4'd5, 200000.0, "RUN after the second power-up");
        #2000;
        if (pu_dp !== 1'b1 || rx_en_hs !== 1'b1) err("not running after the second power-up");

        $display("--------------------------------------------------");
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
