//-----------------------------------------------------------------------------
// tb_usb_afe_tx_if.v - TX data boundary through the AFE models (phase A2)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_tx_if usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_afe_tx_if.v \
//            afe_line_bm.v afe_term_bm.v afe_hs_tx_bm.v afe_fsls_bm.v \
//            tb_usb_afe_tx_if.v
//   vvp sim_afe_tx_if
//
// Chain (AFE_INTEGRATION_PLAN.md phase A2)
//   usb_tx_path -> usb_afe_tx_if (DUT) -> afe_hs_tx_bm (T_EN = 20 ns settling,
//   0.5 ns delay) and afe_fsls_bm -> afe_line_bm with afe_term_bm at both ends
//   (HS: 45 Ohm + 45 Ohm; FS / LS: 1.5 kOhm device pull-up, 15 kOhm host
//   pull-downs) -> line sampler + reference decoder.
//
// Checks, at three levels
//   1. Pins, cycle-exact, every clk_bit cycle (also during reset): a reference
//      model of the DUT built from the serializer outputs (history ring):
//      data delayed by tx_lead + 3, hs_tx_en 3 cycles after tx_en (so tx_lead
//      before the data) until tx_lead + 3 + tx_lag after it, J during
//      the lead, EOP level held during the lag, hs_tx_n = !hs_tx_p, FS/LS
//      driver controls, driver select by speed, clamp (drv_dis / iso_en) to the
//      idle values with the rest of the packet dropped, tx_lead / tx_lag taken
//      over only when idle, reset values, tx_active.
//   2. Line, electrical, HS: sampled 1.0 ns after every clk_bit edge.  The
//      line must be idle (< 50 mV) while TX_EN is low or the driver has not
//      settled (T_EN after TX_EN rose), and J / K with |DP - DM| = 400 mV +-20 mV
//      (polarity: hs_tx_p = 1 -> DP high) after that.  Per packet: J preamble
//      bits and lost SYNC bits must be max(0, lead - jmin) and
//      max(0, jmin - lead), jmin = first sample after settling; so with
//      tx_lead >= T_EN / bit time the whole SYNC is on the line.  The model's
//      P/N skew detector (P = N longer than 0.1 ns) must never fire, except in
//      the case where the testbench injects 0.25 ns skew on TX_IN_N to show it
//      works.
//      FS / LS: once the driver pins have been stable for longer than the slew
//      ramp, DP / DM must show J / K / SE0 at the levels (J = DP high at FS,
//      DM high at LS: polarity of fs_dat / fs_ls).
//   3. Line, protocol: reference decoders on the line, independent of the DUT
//      pins.  HS: line symbols, NRZI decode from J, SYNC, bit unstuffing, EOP =
//      bit-stuff violation on a byte boundary; bytes must equal PID + payload,
//      and the EOP must be 8 + tx_lag bits long.  FS / LS: DP / DM levels
//      sampled in the middle of each bit from the first K on; 8-bit SYNC, bit
//      unstuffing, EOP = 2 bits SE0 then J on a byte boundary, same bytes.
//
// Cases: lead / lag sweep (lead 0, 3, 9, 10, 17, 31; lag 0, 1, 7), a tx_lead
// change during a packet, back-to-back packets with lead 31 / lag 7, P/N skew
// injection, clamp in the middle of an HS packet (drv_dis) and an FS packet
// (iso_en), clamp released in the middle of a packet, FS, FS-rate (11) and LS
// packets.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_afe_tx_if;
    parameter real HALF  = 1.0416667;            // 480 MHz
    parameter real UI    = 2.0 * HALF;
    parameter real T_EN  = 20.0;                 // HS driver settling (model)
    parameter real S_OFF = 1.0;                  // line sample offset after the edge

    integer errors = 0;
    integer seed   = 32'h0A2F_7EE1;

    // ---------------- clock / reset ----------------
    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;
    reg rst_n = 1'b0;
    reg [2:0] ce_cnt = 3'd0;
    wire ce60 = (ce_cnt == 3'd7);
    always @(posedge clk_bit) ce_cnt <= ce_cnt + 3'd1;

    // ---------------- transmitter (usb_tx_path) ----------------
    reg  [7:0] f_b  [0:255];
    reg        f_lm [0:255];                     // last byte of a packet
    integer    f_n = 0, f_idx = 0;
    reg        f_valid = 1'b0, f_last = 1'b0;
    reg  [7:0] f_data = 8'd0;
    reg  [1:0] spd = 2'b00;
    reg        byp_r = 1'b0, eopd_r = 1'b0, lead_first_r = 1'b0;   // OpMode 10 (phase [7])
    wire       f_ready, s_txd, s_en, s_se0, t_busy, t_done, t_under;
    wire [1:0] s_spd;

    usb_tx_path u_tx (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(spd), .bypass_en(byp_r), .eop_dis(eopd_r),
        .in_valid(f_valid), .in_ready(f_ready), .in_data(f_data), .in_last(f_last),
        .txd(s_txd), .tx_en(s_en), .tx_se0(s_se0), .tx_speed(s_spd),
        .busy(t_busy), .tx_done(t_done), .tx_underrun(t_under));

    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            if (f_valid && f_ready) f_idx = f_idx + 1;
            if (f_idx < f_n) begin
                f_valid <= 1'b1; f_data <= f_b[f_idx]; f_last <= f_lm[f_idx];
            end else
                f_valid <= 1'b0;
        end
        if (t_under) begin errors = errors + 1; $display("ERROR @%0t: TX underrun (testbench)", $time); end
    end

    // ---------------- DUT ----------------
    reg  [4:0] lead_r = 5'd10;
    reg  [2:0] lag_r  = 3'd0;
    reg        drv_dis = 1'b0, iso_en = 1'b0;
    wire       hs_p, hs_n, hs_en, fs_oe, fs_dat, fs_se0, fs_ls, tx_act;

    usb_afe_tx_if dut (
        .clk_bit(clk_bit), .rst_n(rst_n),
        .txd(s_txd), .tx_en(s_en), .tx_se0(s_se0), .tx_speed(s_spd),
        .tx_lead(lead_r), .tx_lag(lag_r), .drv_dis(drv_dis), .iso_en(iso_en), .lead_first(lead_first_r),
        .hs_tx_p(hs_p), .hs_tx_n(hs_n), .hs_tx_en(hs_en),
        .fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls),
        .tx_active(tx_act));

    // ---------------- analog models ----------------
    real skew_inj = 0.0;                         // ns, extra delay on TX_IN_N
    reg  hs_n_sk = 1'b0;
    always @(hs_n) hs_n_sk <= #(skew_inj) hs_n;

    reg hs_case = 1'b1;                          // 1: HS terminations, 0: FS / LS pulls
    reg pu_dp = 1'b0, pu_dm = 1'b0;

    wire [63:0] nt_dpg, nt_dpi, nt_dmg, nt_dmi, ft_dpg, ft_dpi, ft_dmg, ft_dmi;
    wire [63:0] hx_dpg, hx_dpi, hx_dmg, hx_dmi, fx_dpg, fx_dpi, fx_dmg, fx_dmi;
    wire [63:0] dp_v, dm_v;
    wire        hx_settled;
    wire [31:0] skew_err;
    wire        rxdp_u, rxdm_u, rxrcv_u;

    afe_term_bm u_nt (.dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(hs_case),
                      .dp_pulldown_en(1'b0), .dm_pulldown_en(1'b0),
                      .dp_g(nt_dpg), .dp_i(nt_dpi), .dm_g(nt_dmg), .dm_i(nt_dmi));
    afe_term_bm u_ft (.dp_pullup_en(1'b0), .dm_pullup_en(1'b0), .hs_term_en(hs_case),
                      .dp_pulldown_en(1'b1), .dm_pulldown_en(1'b1),
                      .dp_g(ft_dpg), .dp_i(ft_dpi), .dm_g(ft_dmg), .dm_i(ft_dmi));
    afe_hs_tx_bm #(.T_EN(T_EN), .T_DLY(0.5), .T_SKEW_MAX(0.1)) u_hx (
        .TX_IN_P(hs_p), .TX_IN_N(hs_n_sk), .TX_EN(hs_en),
        .dp_g(hx_dpg), .dp_i(hx_dpi), .dm_g(hx_dmg), .dm_i(hx_dmi),
        .settled(hx_settled), .skew_err(skew_err));
    afe_fsls_bm u_fx (
        .fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls),
        .dp_g(fx_dpg), .dp_i(fx_dpi), .dm_g(fx_dmg), .dm_i(fx_dmi),
        .rx_en(1'b0), .dp_v(dp_v), .dm_v(dm_v), .rxdp(rxdp_u), .rxdm(rxdm_u), .rxrcv(rxrcv_u));
    afe_line_bm u_line (
        .dp_g0(nt_dpg), .dp_i0(nt_dpi), .dp_g1(ft_dpg), .dp_i1(ft_dpi),
        .dp_g2(hx_dpg), .dp_i2(hx_dpi), .dp_g3(fx_dpg), .dp_i3(fx_dpi),
        .dp_g4(64'd0), .dp_i4(64'd0), .dp_g5(64'd0), .dp_i5(64'd0),
        .dm_g0(nt_dmg), .dm_i0(nt_dmi), .dm_g1(ft_dmg), .dm_i1(ft_dmi),
        .dm_g2(hx_dmg), .dm_i2(hx_dmi), .dm_g3(fx_dmg), .dm_i3(fx_dmi),
        .dm_g4(64'd0), .dm_i4(64'd0), .dm_g5(64'd0), .dm_i5(64'd0),
        .dp_v(dp_v), .dm_v(dm_v));

    // =====================================================================
    // 1. Pin-level reference model
    // =====================================================================
    reg     H_en [0:63], H_d [0:63], H_se0 [0:63], H_hs [0:63], H_ls [0:63];
    integer n = 0, lead_tb = 0, lag_tb = 0, quiet_tb = 0, pk_lead = 0, pk_lag = 0;
    integer k, idx, D, pin_err = 0;
    integer cfg_lead = 0, cfg_lag = 0;
    reg     cfg_tb = 1'b0;
    reg     kill_tb = 1'b0, clamp_prev = 1'b0, cl_tb = 1'b0, clamp_now, en_in, prev_en_in = 1'b0;
    reg     o_hs, o_fs, hs_on;
    reg     E_p = 1'b1, E_en = 1'b0, E_oe = 1'b0, E_dat = 1'b1, E_se0 = 1'b0, E_ls = 1'b0, E_act;

    task ring_idle;
        integer j;
        begin
            for (j = 0; j < 64; j = j + 1) begin
                H_en[j] = 1'b0; H_d[j] = 1'b1; H_se0[j] = 1'b0; H_hs[j] = 1'b0; H_ls[j] = 1'b0;
            end
        end
    endtask
    initial ring_idle;

    task pin_check(input [8*12-1:0] what, input got, input exp);
        begin
            if (got !== exp) begin
                pin_err = pin_err + 1;
                if (pin_err <= 20)
                    $display("ERROR @%0t: pin %0s = %b, expected %b (lead %0d, lag %0d)",
                             $time, what, got, exp, lead_tb, lag_tb);
            end
        end
    endtask

    always @(posedge clk_bit) begin
        if (!rst_n) begin
            // reset values (spec 3.1 / 3.4)
            pin_check("hs_tx_p", hs_p, 1'b1);   pin_check("hs_tx_n", hs_n, 1'b0);
            pin_check("hs_tx_en", hs_en, 1'b0); pin_check("fs_oe", fs_oe, 1'b0);
            pin_check("fs_dat", fs_dat, 1'b1);  pin_check("fs_se0", fs_se0, 1'b0);
            pin_check("fs_ls", fs_ls, 1'b0);    pin_check("tx_active", tx_act, 1'b0);
            ring_idle;
            kill_tb = 1'b0; quiet_tb = 0; lead_tb = 0; lag_tb = 0; clamp_prev = 1'b0; cl_tb = 1'b0; cfg_tb = 1'b0;
            E_p = 1'b1; E_ls = 1'b0;
        end else begin
            // expected pins for this edge (values set at the previous edge)
            D = lead_tb + 3;
            hs_on = 1'b0;
            for (k = 3; k <= D + lag_tb; k = k + 1)
                hs_on = hs_on | (H_en[(n - k) & 63] & H_hs[(n - k) & 63]);
            idx  = (n - D) & 63;
            o_hs = H_en[idx] & H_hs[idx];
            o_fs = H_en[idx] & ~H_hs[idx];
            if (clamp_prev) begin
                E_p = 1'b1; E_en = 1'b0; E_oe = 1'b0; E_dat = 1'b1; E_se0 = 1'b0; E_ls = 1'b0;
            end else begin
                // lead start (TX_EN was low): J, or the first bit with lead_first
                E_p   = o_hs ? H_d[idx] : (hs_on ? (E_en ? E_p : (lead_first_r ? H_d[(n - 3) & 63] : 1'b1)) : 1'b1);
                E_en  = hs_on;
                E_oe  = o_fs;
                E_dat = ~o_fs | H_d[idx];
                E_se0 = o_fs & H_se0[idx];
                E_ls  = o_fs ? H_ls[idx] : E_ls;
            end
            E_act = H_en[(n - 1) & 63] | E_en | E_oe;
            pin_check("hs_tx_p", hs_p, E_p);    pin_check("hs_tx_n", hs_n, ~E_p);
            pin_check("hs_tx_en", hs_en, E_en); pin_check("fs_oe", fs_oe, E_oe);
            pin_check("fs_dat", fs_dat, E_dat); pin_check("fs_se0", fs_se0, E_se0);
            pin_check("fs_ls", fs_ls, E_ls);    pin_check("tx_active", tx_act, E_act);

            // history entry of this edge
            clamp_now = cl_tb;                   // the DUT registers drv_dis | iso_en
            if (clamp_now) ring_idle;
            en_in = s_en & ~clamp_now & ~kill_tb;
            idx = n & 63;
            H_en[idx]  = en_in;
            H_d[idx]   = ~en_in | s_txd;
            H_se0[idx] = en_in & s_se0;
            H_hs[idx]  = en_in & (s_spd == 2'b00);
            H_ls[idx]  = en_in & (s_spd == 2'b10);
            if (en_in && !prev_en_in) begin pk_lead = lead_tb; pk_lag = lag_tb; end
            prev_en_in = en_in;
            kill_tb = clamp_now | (kill_tb & s_en);
            if (cfg_tb) begin lead_tb = cfg_lead; lag_tb = cfg_lag; end
            cfg_tb = (quiet_tb == 127) && !s_en;      // the DUT takes it over one edge later
            cfg_lead = lead_r; cfg_lag = lag_r;
            quiet_tb = s_en ? 0 : ((quiet_tb == 127) ? 127 : quiet_tb + 1);
            clamp_prev = clamp_now;
            cl_tb = drv_dis | iso_en;
            n = n + 1;
        end
    end

    // =====================================================================
    // 2. Line, electrical
    // =====================================================================
    localparam [1:0] SY_I = 2'd0, SY_J = 2'd1, SY_K = 2'd2, SY_X = 2'd3;
    real    t_en_rise = -1.0e9, vp, vm, vd;
    reg     settled_e, data_ph = 1'b0;
    reg [1:0] sym, exp_sym;
    integer el_err = 0, st_pre_j = 0, st_lost = 0, n_hs_smp = 0;
    integer jmin;
    initial begin
        jmin = 0;
        while (jmin * UI + S_OFF < T_EN - 1.0e-6) jmin = jmin + 1;
    end

    always @(posedge hs_en) t_en_rise = $realtime;
    integer n_en_rise = 0, n_s_rise = 0;
    always @(posedge hs_en) n_en_rise = n_en_rise + 1;
    always @(posedge s_en)  n_s_rise  = n_s_rise + 1;

    // FS / LS state
    reg [3:0] fs_prev = 4'd0;
    integer   fs_stable = 0, n_fs_chk = 0, fs_err = 0;
    reg       fs_ok;
    real      v_hi, v_lo;

    always @(posedge clk_bit) begin
        #(S_OFF);
        vp = $bitstoreal(dp_v); vm = $bitstoreal(dm_v); vd = vp - vm;
        if (rst_n && hs_case) begin
            settled_e = hs_en && ($realtime - t_en_rise >= T_EN - 1.0e-6);
            exp_sym   = settled_e ? (hs_p ? SY_J : SY_K) : SY_I;
            if ((vd > 0.2) && (vm < 0.05))       sym = SY_J;
            else if ((vd < -0.2) && (vp < 0.05)) sym = SY_K;
            else if ((vp < 0.05) && (vm < 0.05) && (vd < 0.05) && (vd > -0.05)) sym = SY_I;
            else                                 sym = SY_X;
            if (sym !== exp_sym) begin
                el_err = el_err + 1;
                if (el_err <= 20)
                    $display("ERROR @%0t: line DP %0.3f DM %0.3f V, symbol %0d, expected %0d", $time, vp, vm, sym, exp_sym);
            end
            if (settled_e && ((vd < 0.0 ? -vd : vd) < 0.38 || (vd < 0.0 ? -vd : vd) > 0.42)) begin
                el_err = el_err + 1;
                if (el_err <= 20) $display("ERROR @%0t: HS level |DP - DM| = %0.3f V", $time, vd);
            end
            if (settled_e) n_hs_smp = n_hs_smp + 1;
            // lead statistics: J before the first SYNC K, SYNC bits before settling
            if (!hs_en) data_ph = 1'b0;
            else if (!hs_p) data_ph = 1'b1;
            if (hs_en && !data_ph && settled_e) st_pre_j = st_pre_j + 1;
            if (hs_en &&  data_ph && !settled_e) st_lost = st_lost + 1;
            dec_sym(sym);
        end
        if (rst_n && !hs_case) begin
            if ({fs_oe, fs_dat, fs_se0, fs_ls} !== fs_prev) fs_stable = 0; else fs_stable = fs_stable + 1;
            fs_prev = {fs_oe, fs_dat, fs_se0, fs_ls};
            if (fs_oe && (fs_stable >= (pu_dm ? 100 : 10))) begin
                v_hi = pu_dm ? vm : vp;          // the wire that is high for J (LS: DM)
                v_lo = pu_dm ? vp : vm;
                if (fs_se0)      fs_ok = (vp < 0.3) && (vm < 0.3);
                else if (fs_dat) fs_ok = (v_hi > 2.8) && (v_lo < 0.3);
                else             fs_ok = (v_lo > 2.8) && (v_hi < 0.3);
                n_fs_chk = n_fs_chk + 1;
                if (!fs_ok) begin
                    fs_err = fs_err + 1;
                    if (fs_err <= 20)
                        $display("ERROR @%0t: FS/LS line DP %0.3f DM %0.3f V for oe %b dat %b se0 %b ls %b",
                                 $time, vp, vm, fs_oe, fs_dat, fs_se0, fs_ls);
                end
            end
            fs_line_sym(pu_dm ? vm : vp, pu_dm ? vp : vm, pu_dm ? 320 : 40);
        end
    end

    // =====================================================================
    // 3b. FS / LS reference decoder on the line levels
    //   Line state from the wire voltages only (J = the pulled-up wire high);
    //   the first K after idle starts a packet, then one sample per bit in the
    //   middle of the bit (bit period P clk_bit cycles), until SE0 ... J.
    // =====================================================================
    reg  [1:0] fsb [0:4095];
    integer    nfs = 0, fd_t = 0, fs_ok_n = 0, fs_bad_n = 0, fs_jrun = 0;
    reg        fd_act = 1'b0, fs_quiet = 1'b0;
    reg  [1:0] lst;

    task fs_line_sym(input real hi, input real lo, input integer P);
        begin
            if ((hi > 2.8) && (lo < 0.3))      lst = SY_J;
            else if ((lo > 2.8) && (hi < 0.3)) lst = SY_K;
            else if ((hi < 0.3) && (lo < 0.3)) lst = SY_I;     // SE0
            else                               lst = SY_X;     // ramp in progress
            if (!fd_act) begin
                if (lst == SY_K) begin fd_act = 1'b1; fd_t = 0; nfs = 0; fs_jrun = 0; end
            end
            if (fd_act) begin
                if ((fd_t % P) == (P / 2)) begin
                    if (nfs < 4096) fsb[nfs] = lst;
                    nfs = nfs + 1;
                    fs_jrun = (lst == SY_J) ? fs_jrun + 1 : 0;
                    if ((lst == SY_J) && (nfs >= 2) && (fsb[nfs-2] == SY_I)) begin
                        fd_act = 1'b0; fs_decode;
                    end else if (fs_jrun >= 8) begin           // idle without EOP
                        fd_act = 1'b0; fs_fail("no SE0 EOP");
                    end
                end
                fd_t = fd_t + 1;
            end
        end
    endtask

    task fs_fail(input [8*40-1:0] why);
        begin
            fs_bad_n = fs_bad_n + 1;
            if (!fs_quiet) begin
                errors = errors + 1;
                $display("ERROR @%0t: FS/LS line decoder: %0s", $time, why);
            end
        end
    endtask

    task fs_decode;
        integer i, j, st, run, nb, nse0, zeros;
        reg [1:0] prev;
        reg       b, bad;
        reg [7:0] by;
        reg       db [0:4095];
        begin
            prev = SY_J; st = 0; run = 0; nb = 0; nse0 = 0; zeros = 0; bad = 1'b0;
            for (i = 0; i < nfs - 1; i = i + 1) begin
                if (fsb[i] == SY_X) bad = 1'b1;
                if (fsb[i] == SY_I) nse0 = nse0 + 1;
                else if (nse0 != 0) bad = 1'b1;                 // data after SE0
                else begin
                    b = (fsb[i] == prev); prev = fsb[i];
                    case (st)
                        0: if (!b) zeros = zeros + 1; else begin st = 1; run = 1; end
                        1: if (run == 6) begin
                               if (b) bad = 1'b1;               // stuff error
                               run = 0;
                           end else begin
                               db[nb] = b; nb = nb + 1;
                               run = b ? run + 1 : 0;
                           end
                    endcase
                end
            end
            if (bad)                         fs_fail("invalid symbol / stuff error");
            else if (zeros != 7)             fs_fail("SYNC");
            else if (nse0 != 2)              fs_fail("EOP: SE0 not 2 bits");
            else if ((nb % 8) != 0)          fs_fail("EOP not on a byte boundary");
            else if (nb / 8 != exp_n)        fs_fail("byte count");
            else begin
                for (j = 0; j < nb / 8; j = j + 1) begin
                    for (i = 0; i < 8; i = i + 1) by[i] = db[8 * j + i];
                    if (by !== exp_b[j]) bad = 1'b1;
                end
                if (bad) fs_fail("byte mismatch");
                else     fs_ok_n = fs_ok_n + 1;
            end
        end
    endtask

    // =====================================================================
    // 3. HS reference decoder on the line symbols
    // =====================================================================
    reg  [1:0] sb [0:4095];
    integer    ns = 0, dec_ok = 0, dec_bad = 0, exp_n = 0, dec_zeros = 0;
    reg        in_pkt = 1'b0, dec_en = 1'b1, dec_quiet = 1'b0;
    reg  [7:0] exp_b [0:255];

    task dec_sym(input [1:0] s);
        begin
            if (s != SY_I) begin
                if (ns < 4096) sb[ns] = s;
                ns = ns + 1; in_pkt = 1'b1;
            end else if (in_pkt) begin
                if (dec_en) decode;
                in_pkt = 1'b0; ns = 0;
            end
        end
    endtask

    task dec_fail(input [8*40-1:0] why);
        begin
            dec_bad = dec_bad + 1;
            if (!dec_quiet) begin
                errors = errors + 1;
                $display("ERROR @%0t: line decoder: %0s", $time, why);
            end
        end
    endtask

    task decode;
        integer i, run, nb, nby, j, trail, st;
        reg [1:0] prev;
        reg       b, bad, done;
        reg [7:0] by;
        reg       db [0:4095];
        begin
            bad = 1'b0; done = 1'b0; prev = SY_J; st = 0; dec_zeros = 0;
            run = 0; nb = 0; trail = 0;
            for (i = 0; i < ns && i < 4096; i = i + 1) begin
                if (sb[i] == SY_X) bad = 1'b1;
                b = (sb[i] == prev); prev = sb[i];
                case (st)
                    0: if (!b) begin st = 1; dec_zeros = 1; end          // skip J preamble
                    1: if (!b) dec_zeros = dec_zeros + 1;
                       else begin st = 2; run = 1; end                   // final SYNC 1
                    2: if (run == 6) begin
                           if (b) begin st = 3; done = 1'b1; end         // bit-stuff violation: EOP
                           else run = 0;                                 // stuff bit
                       end else begin
                           db[nb] = b; nb = nb + 1;
                           run = b ? run + 1 : 0;
                       end
                    3: begin if (!b) bad = 1'b1; trail = trail + 1; end
                endcase
            end
            if (bad)                                       dec_fail("invalid symbol or transition in EOP");
            else if (!done)                                dec_fail("no EOP (bit-stuff violation)");
            else if ((nb < 7) || (((nb - 7) % 8) != 0))    dec_fail("EOP not on a byte boundary");
            else if ((db[nb-7] != 1'b0) || (db[nb-6] & db[nb-5] & db[nb-4] & db[nb-3] & db[nb-2] & db[nb-1]) != 1'b1)
                                                           dec_fail("EOP pattern");
            else if (trail != pk_lag)                      dec_fail("EOP length != 8 + tx_lag");
            else begin
                nby = (nb - 7) / 8;
                if (nby != exp_n) dec_fail("byte count");
                else begin
                    for (j = 0; j < nby; j = j + 1) begin
                        for (i = 0; i < 8; i = i + 1) by[i] = db[8 * j + i];
                        if (by !== exp_b[j]) bad = 1'b1;
                    end
                    if (bad) dec_fail("byte mismatch");
                    else     dec_ok = dec_ok + 1;
                end
            end
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    reg [7:0] pids [0:9];
    initial begin
        pids[0] = 8'hC3; pids[1] = 8'h4B; pids[2] = 8'h87; pids[3] = 8'h0F; pids[4] = 8'h69;
        pids[5] = 8'hE1; pids[6] = 8'hA5; pids[7] = 8'h2D; pids[8] = 8'hD2; pids[9] = 8'h5A;
    end

    // append one packet to the feeder queue (does not start it)
    task add_pkt(input [1:0] s, input integer npay, input integer ffs);
        integer i, b0;
        begin
            b0 = f_n;
            if (s == 2'b00) begin
                f_b[f_n] = 8'h00; f_b[f_n+1] = 8'h00; f_b[f_n+2] = 8'h00; f_b[f_n+3] = 8'h80;
                f_lm[f_n] = 0; f_lm[f_n+1] = 0; f_lm[f_n+2] = 0; f_lm[f_n+3] = 0;
                f_n = f_n + 4;
            end else begin
                f_b[f_n] = 8'h80; f_lm[f_n] = 0; f_n = f_n + 1;
            end
            exp_n = npay + 1;
            exp_b[0] = pids[{$random(seed)} % 10];
            for (i = 1; i <= npay; i = i + 1)
                exp_b[i] = (ffs || ({$random(seed)} % 4 == 0)) ? 8'hFF : $random(seed);
            for (i = 0; i <= npay; i = i + 1) begin f_b[f_n] = exp_b[i]; f_lm[f_n] = (i == npay); f_n = f_n + 1; end
        end
    endtask

    task go(input [1:0] s);
        begin
            @(negedge clk_bit);
            spd = s; f_idx = 0;
        end
    endtask

    task wait_done;
        begin
            @(posedge clk_bit);
            while ((f_idx < f_n) || t_busy || s_en || tx_act) @(posedge clk_bit);
            repeat (300) @(posedge clk_bit);           // idle gap > 2^QW: config may load
            f_n = 0; f_idx = 0;
        end
    endtask

    // set the HS / FS / LS line environment
    task env(input [1:0] s);
        begin
            @(negedge clk_bit);
            hs_case = (s == 2'b00);
            pu_dp   = (s == 2'b01) || (s == 2'b11);
            pu_dm   = (s == 2'b10);
            repeat (200) @(posedge clk_bit);
        end
    endtask

    integer ok0, bad0, sk0, fok0, fbad0;

    task fs_pkt(input [1:0] s, input integer npay, input integer ffs);
        begin
            fok0 = fs_ok_n; fbad0 = fs_bad_n;
            f_n = 0; add_pkt(s, npay, ffs); f_idx = f_n; go(s); wait_done;
            if ((fs_ok_n != fok0 + 1) || (fs_bad_n != fbad0)) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s packet not decoded at the line", $time, (s == 2'b10) ? "LS" : "FS");
            end
        end
    endtask

    // one normal HS packet with full checking of decoder and lead statistics
    task hs_pkt(input integer npay, input integer ffs);
        integer ep, el;
        begin
            ok0 = dec_ok; bad0 = dec_bad; sk0 = skew_err;
            st_pre_j = 0; st_lost = 0;
            f_n = 0; add_pkt(2'b00, npay, ffs);
            f_idx = f_n;
            go(2'b00);
            wait_done;
            ep = (pk_lead > jmin) ? pk_lead - jmin : 0;
            el = (jmin > pk_lead) ? jmin - pk_lead : 0;
            if ((dec_ok != ok0 + 1) || (dec_bad != bad0)) begin
                errors = errors + 1;
                $display("ERROR @%0t: HS packet not decoded at the line (lead %0d, lag %0d)", $time, pk_lead, pk_lag);
            end
            if ((st_pre_j != ep) || (st_lost != el)) begin
                errors = errors + 1;
                $display("ERROR @%0t: lead %0d: J preamble %0d bits (expected %0d), lost SYNC bits %0d (expected %0d)",
                         $time, pk_lead, st_pre_j, ep, st_lost, el);
            end
            if (skew_err != sk0) begin
                errors = errors + 1; $display("ERROR @%0t: P/N skew detected at the TX input", $time);
            end
        end
    endtask

    task set_cfg(input integer ld, input integer lg);
        begin
            @(negedge clk_bit);
            lead_r = ld; lag_r = lg;
            repeat (200) @(posedge clk_bit);
        end
    endtask

    integer li, gi, i;
    integer leads [0:5];
    integer lags  [0:2];

    initial begin
        $dumpfile("tb_usb_afe_tx_if.vcd");
        $dumpvars(0, tb_usb_afe_tx_if);
        leads[0] = 0; leads[1] = 3; leads[2] = 9; leads[3] = 10; leads[4] = 17; leads[5] = 31;
        lags[0] = 0; lags[1] = 1; lags[2] = 7;

        repeat (20) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (200) @(posedge clk_bit);
        $display("    T_EN = %0.1f ns, first line sample after settling: bit %0d -> full SYNC for tx_lead >= %0d",
                 T_EN, jmin, jmin);

        // ---------------- [1] HS lead / lag sweep ----------------
        $display("[1] HS lead / lag sweep");
        env(2'b00);
        for (li = 0; li < 6; li = li + 1)
            for (gi = 0; gi < 3; gi = gi + 1) begin
                set_cfg(leads[li], lags[gi]);
                hs_pkt(1 + {$random(seed)} % 16, 0);
                hs_pkt(4, 1);                                   // 0xFF payload: stuffing
                if (gi == 0)
                    $display("    lead %2d: J preamble %0d bit(s), SYNC bits lost %0d", pk_lead, st_pre_j, st_lost);
            end

        // ---------------- [2] tx_lead change during a packet ----------------
        $display("[2] tx_lead / tx_lag change during a packet");
        set_cfg(10, 2);
        ok0 = dec_ok; bad0 = dec_bad;
        f_n = 0; add_pkt(2'b00, 20, 0); f_idx = f_n;
        go(2'b00);
        @(posedge s_en); repeat (40) @(posedge clk_bit);
        @(negedge clk_bit) begin lead_r = 25; lag_r = 5; end
        wait_done;
        if ((dec_ok != ok0 + 1) || (pk_lead != 10) || (pk_lag != 2)) begin
            errors = errors + 1; $display("ERROR: packet with the config change (lead %0d lag %0d)", pk_lead, pk_lag);
        end
        hs_pkt(6, 0);
        if ((pk_lead != 25) || (pk_lag != 5)) begin
            errors = errors + 1; $display("ERROR: new lead / lag not taken over (%0d, %0d)", pk_lead, pk_lag);
        end

        // ---------------- [3] back-to-back packets ----------------
        $display("[3] back-to-back HS packets, lead 31, lag 7 (pins only)");
        set_cfg(31, 7);
        dec_en = 1'b0;
        f_n = 0; add_pkt(2'b00, 3, 0); add_pkt(2'b00, 5, 0); f_idx = f_n;
        n_en_rise = 0; n_s_rise = 0;
        go(2'b00);
        wait_done;
        dec_en = 1'b1;
        if ((n_s_rise != 2) || (n_en_rise != 1)) begin
            errors = errors + 1;
            $display("ERROR: back-to-back: %0d serializer packets, %0d TX_EN pulses (expected 2 / 1)", n_s_rise, n_en_rise);
        end else
            $display("    2 packets, gap shorter than lead + lag: one continuous TX_EN pulse");

        // ---------------- [4] P/N skew injection ----------------
        $display("[4] P/N skew injection (0.25 ns on TX_IN_N)");
        set_cfg(10, 0);
        sk0 = skew_err;
        skew_inj = 0.25;
        f_n = 0; add_pkt(2'b00, 8, 0); f_idx = f_n;
        go(2'b00);
        wait_done;
        skew_inj = 0.0;
        if (skew_err == sk0) begin errors = errors + 1; $display("ERROR: injected P/N skew not detected"); end
        else $display("    skew events detected: %0d", skew_err - sk0);
        hs_pkt(8, 0);

        // ---------------- [5] clamp ----------------
        $display("[5] clamp: drv_dis / iso_en");
        // (a) drv_dis in the middle of an HS packet, released before its end
        ok0 = dec_ok; bad0 = dec_bad; dec_quiet = 1'b1;
        f_n = 0; add_pkt(2'b00, 30, 0); f_idx = f_n;
        go(2'b00);
        @(posedge s_en); repeat (90) @(posedge clk_bit);
        @(negedge clk_bit) drv_dis = 1'b1;
        repeat (40) @(posedge clk_bit);
        @(negedge clk_bit) drv_dis = 1'b0;
        if (!s_en) begin errors = errors + 1; $display("ERROR: TB: packet ended before the clamp release"); end
        wait_done;
        dec_quiet = 1'b0;
        if ((dec_ok != ok0) || (dec_bad != bad0 + 1)) begin
            errors = errors + 1; $display("ERROR: clamped HS packet: %0d ok, %0d bad (expected 0 / 1)", dec_ok - ok0, dec_bad - bad0);
        end
        hs_pkt(5, 0);
        // (b) iso_en before the packet, released in its middle: nothing is sent
        ok0 = dec_ok; bad0 = dec_bad;
        @(negedge clk_bit) iso_en = 1'b1;
        f_n = 0; add_pkt(2'b00, 30, 0); f_idx = f_n;
        go(2'b00);
        @(posedge s_en); repeat (60) @(posedge clk_bit);
        @(negedge clk_bit) iso_en = 1'b0;
        wait_done;
        if ((dec_ok != ok0) || (dec_bad != bad0)) begin
            errors = errors + 1; $display("ERROR: packet started under iso_en reached the line");
        end
        hs_pkt(5, 0);

        // ---------------- [6] FS / LS ----------------
        $display("[6] FS / LS driver controls and line levels");
        set_cfg(10, 3);
        env(2'b01);
        for (i = 0; i < 3; i = i + 1) fs_pkt(2'b01, 2 + i * 3, i == 1);
        fs_pkt(2'b11, 3, 0);
        // iso_en in the middle of an FS packet: truncated on the line, no EOP
        fok0 = fs_ok_n; fbad0 = fs_bad_n; fs_quiet = 1'b1;
        f_n = 0; add_pkt(2'b01, 6, 0); f_idx = f_n; go(2'b01);
        @(posedge s_en); repeat (700) @(posedge clk_bit);
        @(negedge clk_bit) iso_en = 1'b1;
        repeat (100) @(posedge clk_bit);
        wait_done;
        @(negedge clk_bit) iso_en = 1'b0;
        fs_quiet = 1'b0;
        if ((fs_ok_n != fok0) || (fs_bad_n != fbad0 + 1)) begin
            errors = errors + 1; $display("ERROR: clamped FS packet: %0d ok, %0d bad (expected 0 / 1)", fs_ok_n - fok0, fs_bad_n - fbad0);
        end
        fs_pkt(2'b01, 2, 0);
        env(2'b10);
        for (i = 0; i < 2; i = i + 1) fs_pkt(2'b10, 1 + i, i == 1);
        $display("    FS/LS line checks: %0d samples, packets decoded %0d", n_fs_chk, fs_ok_n);
        if (n_fs_chk < 1000) begin errors = errors + 1; $display("ERROR: too few FS/LS line checks"); end

        // ---------------- [7] OpMode 10 chirps: lead level ----------------
        $display("[7] HS chirp K / J (bypass, no EOP): lead at J vs. lead_first");
        env(2'b00);
        set_cfg(17, 0);                                 // lead well beyond T_EN: a visible J
        @(negedge clk_bit) begin byp_r = 1'b1; eopd_r = 1'b1; end
        dec_en = 1'b0;
        for (i = 0; i < 3; i = i + 1) begin
            lead_first_r = (i != 0);
            f_n = 0;
            for (gi = 0; gi < 40; gi = gi + 1) begin
                f_b[gi] = (i == 2) ? 8'hFF : 8'h00; f_lm[gi] = (gi == 39);
            end
            f_n = 40; f_idx = f_n;
            st_pre_j = 0; st_lost = 0;
            go(2'b00);
            wait_done;
            // chirp K: J samples before the K while the driver is settled
            if (i == 0) begin
                $display("    chirp K, lead_first 0: %0d J sample(s) on the line before the K", st_pre_j);
                if (st_pre_j != pk_lead - jmin) begin errors = errors + 1; $display("ERROR: expected %0d J samples", pk_lead - jmin); end
            end else if (i == 1) begin
                $display("    chirp K, lead_first 1: %0d J sample(s) before the K", st_pre_j);
                if (st_pre_j != 0) begin errors = errors + 1; $display("ERROR: J on the line before a chirp K with lead_first"); end
            end
        end
        @(negedge clk_bit) begin byp_r = 1'b0; eopd_r = 1'b0; lead_first_r = 1'b0; end
        dec_en = 1'b1;
        hs_pkt(4, 0);

        // ---------------- summary ----------------
        $display("    pins checked for %0d cycles, HS line samples (driver settled) %0d, packets decoded %0d",
                 n, n_hs_smp, dec_ok);
        errors = errors + pin_err + el_err + fs_err;
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
