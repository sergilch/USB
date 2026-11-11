//-----------------------------------------------------------------------------
// tb_usb_afe_fsls.v - FS / LS loopback and LineState through the AFE models
//                     (AFE_INTEGRATION_PLAN.md phase A5)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_fsls usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_afe_tx_if.v \
//            usb_rx_nrzi_decoder.v usb_rx_sync_detect.v usb_rx_bit_unstuffer.v \
//            usb_rx_deserializer.v usb_rx_eop_check.v usb_rx_decoder.v \
//            usb_rx_elastic_buffer.v usb_rx_hs_frontend.v usb_rx_fsls_frontend.v \
//            usb_rx_datapath.v usb_rx_status_flt.v usb_rx_status_sync.v \
//            usb_line_state.v afe_line_bm.v afe_term_bm.v afe_fsls_bm.v \
//            tb_usb_afe_fsls.v
//   vvp sim_afe_fsls
//
// Set-up: two ends on one DP / DM pair (afe_line_bm)
//   * Device (the PHY under test), on clk_bit with ce60:
//       TX: usb_tx_path -> usb_afe_tx_if -> afe_fsls_bm driver
//       RX: afe_fsls_bm receivers -> usb_rx_status_sync -> usb_line_state
//                                                      -> usb_rx_datapath
//       afe_term_bm: 1.5 kOhm pull-up on DP (FS) or DM (LS)
//       The device receivers see D- through an extra delay (skew, 0 / 2 / 4 ns
//       per packet), so every J / K crossover makes an SE0 or SE1 glitch.
//   * Host, on clk_far (ppm offset against clk_bit, +1500 / -1500 ppm):
//       usb_tx_path -> usb_afe_tx_if -> afe_fsls_bm; its receivers feed a
//       second usb_rx_datapath (the host's receiver); afe_term_bm: 15 kOhm
//       pull-downs on DP and DM.
//
// Checks
//   1. Packets, both directions: the receiving end's usb_rx_datapath delivers
//      exactly the packet sent (rx_start, PID + payload, rx_end without
//      rx_error); the sending end's own receiver delivers nothing (local
//      transmitter hold-off on usb_afe_tx_if tx_active); framing (one event per
//      tick, nothing outside a packet).
//   2. LineState against the line, independent of the receiver models: a
//      classifier samples the wire voltages the device receivers see (DP and
//      the skewed DM) every clk_bit cycle against 1.4 V and records the line
//      states with their start times.  Per transfer, segments shorter than G
//      cycles (crossover glitches; G = 16 FS, 100 LS) are dropped and equal
//      neighbours merged.  The sequence of usb_line_state values must equal
//      that sequence, and each change must come 0 .. LJK cycles (J / K) or
//      0 .. LSE cycles (SE0 / SE1) after the segment started:
//        FS: LJK 16, LSE 24 (2-tick SE filter);  LS: LJK 16, LSE 124 (14 ticks).
//      So no glitch is ever shown, every real state is, in order and in time;
//      in particular every packet, also the device's own, ends with SE0 -> J on
//      LineState (ULPI 1.1 3.8.2.2: the Link times FS / LS EOPs with it).
//   3. Attach / detach: LineState J after the pull-up is switched on (FS: 01,
//      LS: 10), SE0 after it is switched off; checked by the same comparison.
// Sequence: FS attach, 16 FS packets alternating host -> device / device ->
// host with random payloads (bit stuffing, 0-24 bytes) and skew, 4 packets
// with XcvrSelect 11 (FS rate), detach, LS attach, 10 LS packets, detach.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_afe_fsls;
    parameter real HALF = 1.0416667;             // 480 MHz

    integer errors = 0;
    integer seed   = 32'h0F5A_15CE;

    // ---------------- clocks / resets ----------------
    reg clk_bit = 1'b0, clk_far = 1'b0;
    real half_f = HALF;
    always #(HALF)   clk_bit = ~clk_bit;
    always #(half_f) clk_far = ~clk_far;
    reg rst_n = 1'b0;
    reg [2:0] ce_cnt = 3'd0, cf_cnt = 3'd0;
    wire ce60  = (ce_cnt == 3'd7);
    wire ce_far = (cf_cnt == 3'd7);
    always @(posedge clk_bit) ce_cnt <= ce_cnt + 3'd1;
    always @(posedge clk_far) cf_cnt <= cf_cnt + 3'd1;

    reg [1:0] spd = 2'b01;                       // XcvrSelect, both ends

    // ---------------- feeders (SYNC + PID + payload) ----------------
    reg  [7:0] pk_b [0:63];                      // packet incl. SYNC
    reg        pk_last [0:63];
    integer    pk_n = 0;

    integer    d_idx = 64, h_idx = 64;           // >= pk_n: idle
    reg        d_valid = 1'b0, d_last = 1'b0, h_valid = 1'b0, h_last = 1'b0;
    reg  [7:0] d_data = 8'd0, h_data = 8'd0;
    wire       d_ready, h_ready;

    always @(posedge clk_bit) if (rst_n && ce60) begin
        if (d_valid && d_ready) d_idx = d_idx + 1;
        if (d_idx < pk_n) begin d_valid <= 1'b1; d_data <= pk_b[d_idx]; d_last <= pk_last[d_idx]; end
        else d_valid <= 1'b0;
    end
    always @(posedge clk_far) if (rst_n && ce_far) begin
        if (h_valid && h_ready) h_idx = h_idx + 1;
        if (h_idx < pk_n) begin h_valid <= 1'b1; h_data <= pk_b[h_idx]; h_last <= pk_last[h_idx]; end
        else h_valid <= 1'b0;
    end

    // ---------------- device TX ----------------
    wire d_txd, d_en, d_se0, d_busy, d_done, d_under;
    wire [1:0] d_spd;
    wire d_hp, d_hn, d_hen, d_oe, d_dat, d_fse0, d_fls, d_act;

    usb_tx_path u_dtx (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(spd), .bypass_en(1'b0),
        .in_valid(d_valid), .in_ready(d_ready), .in_data(d_data), .in_last(d_last),
        .txd(d_txd), .tx_en(d_en), .tx_se0(d_se0), .tx_speed(d_spd),
        .busy(d_busy), .tx_done(d_done), .tx_underrun(d_under));
    usb_afe_tx_if u_dafe (
        .clk_bit(clk_bit), .rst_n(rst_n),
        .txd(d_txd), .tx_en(d_en), .tx_se0(d_se0), .tx_speed(d_spd),
        .tx_lead(5'd10), .tx_lag(3'd0), .drv_dis(1'b0), .iso_en(1'b0),
        .hs_tx_p(d_hp), .hs_tx_n(d_hn), .hs_tx_en(d_hen),
        .fs_oe(d_oe), .fs_dat(d_dat), .fs_se0(d_fse0), .fs_ls(d_fls), .tx_active(d_act));

    // ---------------- host TX ----------------
    wire h_txd, h_en, h_se0, h_busy, h_done, h_under;
    wire [1:0] h_spd;
    wire h_hp, h_hn, h_hen, h_oe, h_dat, h_fse0, h_fls, h_act;

    usb_tx_path u_htx (
        .clk_bit(clk_far), .rst_n(rst_n), .ce60(ce_far), .speed(spd), .bypass_en(1'b0),
        .in_valid(h_valid), .in_ready(h_ready), .in_data(h_data), .in_last(h_last),
        .txd(h_txd), .tx_en(h_en), .tx_se0(h_se0), .tx_speed(h_spd),
        .busy(h_busy), .tx_done(h_done), .tx_underrun(h_under));
    usb_afe_tx_if u_hafe (
        .clk_bit(clk_far), .rst_n(rst_n),
        .txd(h_txd), .tx_en(h_en), .tx_se0(h_se0), .tx_speed(h_spd),
        .tx_lead(5'd10), .tx_lag(3'd0), .drv_dis(1'b0), .iso_en(1'b0),
        .hs_tx_p(h_hp), .hs_tx_n(h_hn), .hs_tx_en(h_hen),
        .fs_oe(h_oe), .fs_dat(h_dat), .fs_se0(h_fse0), .fs_ls(h_fls), .tx_active(h_act));

    always @(posedge clk_bit) if (d_under || h_under) begin
        errors = errors + 1; $display("ERROR @%0t: TX underrun (testbench)", $time);
    end

    // ---------------- analog models ----------------
    reg pu_dp = 1'b0, pu_dm = 1'b0;
    wire [63:0] dt_dpg, dt_dpi, dt_dmg, dt_dmi, ht_dpg, ht_dpi, ht_dmg, ht_dmi;
    wire [63:0] dx_dpg, dx_dpi, dx_dmg, dx_dmi, hx_dpg, hx_dpi, hx_dmg, hx_dmi;
    wire [63:0] dp_v, dm_v;
    reg  [63:0] dm_v_sk = 64'd0;                  // D- as the device receivers see it
    real        skew = 0.0;
    always @(dm_v) dm_v_sk <= #(skew) dm_v;
    wire d_rxdp, d_rxdm, d_rxrcv, h_rxdp, h_rxdm, h_rxrcv;

    afe_term_bm u_dterm (.dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(1'b0),
                         .dp_pulldown_en(1'b0), .dm_pulldown_en(1'b0),
                         .dp_g(dt_dpg), .dp_i(dt_dpi), .dm_g(dt_dmg), .dm_i(dt_dmi));
    afe_term_bm u_hterm (.dp_pullup_en(1'b0), .dm_pullup_en(1'b0), .hs_term_en(1'b0),
                         .dp_pulldown_en(1'b1), .dm_pulldown_en(1'b1),
                         .dp_g(ht_dpg), .dp_i(ht_dpi), .dm_g(ht_dmg), .dm_i(ht_dmi));
    afe_fsls_bm u_dfx (
        .fs_oe(d_oe), .fs_dat(d_dat), .fs_se0(d_fse0), .fs_ls(d_fls),
        .dp_g(dx_dpg), .dp_i(dx_dpi), .dm_g(dx_dmg), .dm_i(dx_dmi),
        .rx_en(1'b1), .dp_v(dp_v), .dm_v(dm_v_sk), .rxdp(d_rxdp), .rxdm(d_rxdm), .rxrcv(d_rxrcv));
    afe_fsls_bm u_hfx (
        .fs_oe(h_oe), .fs_dat(h_dat), .fs_se0(h_fse0), .fs_ls(h_fls),
        .dp_g(hx_dpg), .dp_i(hx_dpi), .dm_g(hx_dmg), .dm_i(hx_dmi),
        .rx_en(1'b1), .dp_v(dp_v), .dm_v(dm_v), .rxdp(h_rxdp), .rxdm(h_rxdm), .rxrcv(h_rxrcv));
    afe_line_bm u_line (
        .dp_g0(dt_dpg), .dp_i0(dt_dpi), .dp_g1(ht_dpg), .dp_i1(ht_dpi),
        .dp_g2(dx_dpg), .dp_i2(dx_dpi), .dp_g3(hx_dpg), .dp_i3(hx_dpi),
        .dp_g4(64'd0), .dp_i4(64'd0), .dp_g5(64'd0), .dp_i5(64'd0),
        .dm_g0(dt_dmg), .dm_i0(dt_dmi), .dm_g1(ht_dmg), .dm_i1(ht_dmi),
        .dm_g2(dx_dmg), .dm_i2(dx_dmi), .dm_g3(hx_dmg), .dm_i3(hx_dmi),
        .dm_g4(64'd0), .dm_i4(64'd0), .dm_g5(64'd0), .dm_i5(64'd0),
        .dp_v(dp_v), .dm_v(dm_v));

    // ---------------- device receive side (DUT) ----------------
    wire s_dp, s_dm, s_rcv, s_sq, s_disc, s_avv, s_sv, s_se, s_id;
    wire [1:0] ls;
    wire       hdisc;

    usb_rx_status_sync u_ss (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60),
        .rxdp(d_rxdp), .rxdm(d_rxdm), .rxrcv(d_rxrcv), .squelch(1'b1), .disc(1'b0),
        .a_vbus_vld(1'b1), .sess_vld(1'b1), .sess_end(1'b0), .id_gnd(1'b0),
        .sq_flt(4'd2), .disc_flt(4'd2), .vb_flt(16'd0),
        .rxdp_s(s_dp), .rxdm_s(s_dm), .rxrcv_s(s_rcv), .squelch_s(s_sq), .disc_s(s_disc),
        .a_vbus_vld_s(s_avv), .sess_vld_s(s_sv), .sess_end_s(s_se), .id_gnd_s(s_id));
    usb_line_state u_ls (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60),
        .rxdp_s(s_dp), .rxdm_s(s_dm), .rxrcv_s(s_rcv), .squelch_s(s_sq), .disc_s(s_disc),
        .xcvrselect(spd), .opmode(2'b00), .host_mode(1'b0), .hs_tx_act(1'b0),
        .linestate(ls), .host_disc(hdisc));

    wire       dr_start, dr_valid, dr_end, dr_error, dr_busy;
    wire [7:0] dr_data;
    usb_rx_datapath u_drx (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(spd), .rx_en(1'b1),
        .tx_en(d_act), .clk_rx(~clk_bit), .hs_rxd(1'b1), .hs_squelch(1'b1), .hs_cdr_lock(1'b0),
        .rxrcv(s_rcv), .rxdp(s_dp), .rxdm(s_dm),
        .rx_start(dr_start), .rx_valid(dr_valid), .rx_data(dr_data), .rx_end(dr_end),
        .rx_error(dr_error), .rx_busy(dr_busy));

    // ---------------- host receiver ----------------
    wire       hr_start, hr_valid, hr_end, hr_error, hr_busy;
    wire [7:0] hr_data;
    usb_rx_datapath u_hrx (
        .clk_bit(clk_far), .rst_n(rst_n), .ce60(ce_far), .speed(spd), .rx_en(1'b1),
        .tx_en(h_act), .clk_rx(~clk_far), .hs_rxd(1'b1), .hs_squelch(1'b1), .hs_cdr_lock(1'b0),
        .rxrcv(h_rxrcv), .rxdp(h_rxdp), .rxdm(h_rxdm),
        .rx_start(hr_start), .rx_valid(hr_valid), .rx_data(hr_data), .rx_end(hr_end),
        .rx_error(hr_error), .rx_busy(hr_busy));

    initial begin
        $dumpfile("tb_usb_afe_fsls.vcd");
        $dumpvars(0, tb_usb_afe_fsls);
    end

    // =====================================================================
    // 1. Packet monitors (outputs sampled on their own ce60)
    // =====================================================================
    reg  [7:0] dm_b [0:63];
    integer    dm_n = 0, dm_pk = 0, dm_err = 0;
    reg        dm_in = 1'b0;
    reg  [7:0] hm_b [0:63];
    integer    hm_n = 0, hm_pk = 0, hm_err = 0;
    reg        hm_in = 1'b0;

    always @(posedge clk_bit) if (rst_n && ce60) begin
        if (dr_start + dr_valid + dr_end > 1) begin errors = errors + 1; $display("ERROR @%0t: device RX: two events in one tick", $time); end
        if (dr_start) begin
            if (dm_in) begin errors = errors + 1; $display("ERROR @%0t: device RX: start inside a packet", $time); end
            dm_in = 1'b1; dm_n = 0;
        end
        if (dr_valid) begin
            if (!dm_in) begin errors = errors + 1; $display("ERROR @%0t: device RX: byte outside a packet", $time); end
            else if (dm_n < 64) begin dm_b[dm_n] = dr_data; dm_n = dm_n + 1; end
        end
        if (dr_end) begin
            if (!dm_in) begin errors = errors + 1; $display("ERROR @%0t: device RX: end outside a packet", $time); end
            dm_in = 1'b0; dm_pk = dm_pk + 1;
            if (dr_error) dm_err = dm_err + 1;
        end
    end

    always @(posedge clk_far) if (rst_n && ce_far) begin
        if (hr_start + hr_valid + hr_end > 1) begin errors = errors + 1; $display("ERROR @%0t: host RX: two events in one tick", $time); end
        if (hr_start) begin
            if (hm_in) begin errors = errors + 1; $display("ERROR @%0t: host RX: start inside a packet", $time); end
            hm_in = 1'b1; hm_n = 0;
        end
        if (hr_valid) begin
            if (!hm_in) begin errors = errors + 1; $display("ERROR @%0t: host RX: byte outside a packet", $time); end
            else if (hm_n < 64) begin hm_b[hm_n] = hr_data; hm_n = hm_n + 1; end
        end
        if (hr_end) begin
            if (!hm_in) begin errors = errors + 1; $display("ERROR @%0t: host RX: end outside a packet", $time); end
            hm_in = 1'b0; hm_pk = hm_pk + 1;
            if (hr_error) hm_err = hm_err + 1;
        end
    end

    // =====================================================================
    // 2. LineState against the line
    // =====================================================================
    localparam NSEG = 4096;
    reg  [1:0] sg_v [0:NSEG-1];                  // line segments
    integer    sg_t [0:NSEG-1];
    integer    sg_n = 0;
    reg  [1:0] dl_v [0:NSEG-1];                  // DUT LineState changes
    integer    dl_t [0:NSEG-1];
    integer    dl_n = 0;
    integer    cyc = 0;
    reg  [1:0] lv, lv_q = 2'b00, ls_q = 2'b00;
    real       vp, vm;

    always @(posedge clk_bit) begin
        cyc = cyc + 1;
        vp = $bitstoreal(dp_v); vm = $bitstoreal(dm_v_sk);
        lv = {vm > 1.4, vp > 1.4};
        if (lv != lv_q && sg_n < NSEG) begin sg_v[sg_n] = lv; sg_t[sg_n] = cyc; sg_n = sg_n + 1; end
        lv_q = lv;
        #0.1;
        if (ls != ls_q && dl_n < NSEG) begin dl_v[dl_n] = ls; dl_t[dl_n] = cyc; dl_n = dl_n + 1; end
        ls_q = ls;
    end

    // start a recording: the line and LineState must agree now (quiet line)
    task ls_start;
        begin
            @(posedge clk_bit); #0.2;
            if (ls !== lv_q) begin
                errors = errors + 1;
                $display("ERROR @%0t: LineState %b on a quiet line in state %b", $time, ls, lv_q);
            end
            sg_n = 1; sg_v[0] = lv_q; sg_t[0] = cyc;
            dl_n = 1; dl_v[0] = ls;   dl_t[0] = cyc;
        end
    endtask

    integer lat_max [0:1];
    integer n_ls_chg = 0;
    initial begin lat_max[0] = 0; lat_max[1] = 0; end

    reg  [1:0] f_v [0:NSEG-1];
    integer    f_t [0:NSEG-1];
    integer    f_n, n_eop;

    // compare the recording; G: glitch length, LJK / LSE: latency limits
    task ls_compare(input [8*24-1:0] what, input integer G, input integer LJK, input integer LSE,
                    input integer eops);
        integer i, dur, lat, lmax, bad;
        begin
            f_n = 0;
            for (i = 0; i < sg_n; i = i + 1) begin
                dur = (i + 1 < sg_n) ? sg_t[i+1] - sg_t[i] : G;
                if (dur >= G || i == 0) begin              // the state at the start always counts
                    if (f_n > 0 && f_v[f_n-1] == sg_v[i]) ;      // merge
                    else begin f_v[f_n] = sg_v[i]; f_t[f_n] = sg_t[i]; f_n = f_n + 1; end
                end
            end
            bad = 0;
            if (f_n != dl_n) bad = 1;
            for (i = 0; i < f_n && i < dl_n && !bad; i = i + 1) begin
                if (f_v[i] != dl_v[i]) bad = 1;
                else if (i > 0) begin
                    lat  = dl_t[i] - f_t[i];
                    lmax = (f_v[i] == 2'b00 || f_v[i] == 2'b11) ? LSE : LJK;
                    if (lat < 0 || lat > lmax) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: %0s: LineState %b shown %0d cycles after the line (limit %0d)",
                                 $time, what, dl_v[i], lat, lmax);
                    end
                    if (lat > lat_max[(f_v[i] == 2'b00 || f_v[i] == 2'b11)])
                        lat_max[(f_v[i] == 2'b00 || f_v[i] == 2'b11)] = lat;
                end
            end
            if (bad) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: LineState sequence (%0d changes) differs from the line (%0d)",
                         $time, what, dl_n, f_n);
                for (i = 0; i < f_n || i < dl_n; i = i + 1)
                    if (i < 40)
                        $display("   %3d  line %b @%0d   linestate %b @%0d", i,
                                 (i < f_n) ? f_v[i] : 2'bxx, (i < f_n) ? f_t[i] : -1,
                                 (i < dl_n) ? dl_v[i] : 2'bxx, (i < dl_n) ? dl_t[i] : -1);
            end
            // EOPs: SE0 followed by J on LineState
            n_eop = 0;
            for (i = 1; i < dl_n; i = i + 1)
                if (dl_v[i-1] == 2'b00 && dl_v[i] == ((spd == 2'b10) ? 2'b10 : 2'b01)) n_eop = n_eop + 1;
            if (eops >= 0 && n_eop != eops) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: %0d SE0 -> J on LineState, expected %0d", $time, what, n_eop, eops);
            end
            n_ls_chg = n_ls_chg + dl_n - 1;
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    reg [7:0] pids [0:9];
    reg [7:0] exp_b [0:63];
    integer   exp_n;
    initial begin
        pids[0] = 8'hC3; pids[1] = 8'h4B; pids[2] = 8'h87; pids[3] = 8'h0F; pids[4] = 8'h69;
        pids[5] = 8'hE1; pids[6] = 8'hA5; pids[7] = 8'h2D; pids[8] = 8'hD2; pids[9] = 8'h5A;
    end

    task make_pkt(input integer npay);
        integer i;
        begin
            exp_n = npay + 1;
            exp_b[0] = pids[{$random(seed)} % 10];
            for (i = 1; i <= npay; i = i + 1)
                exp_b[i] = ({$random(seed)} % 4 == 0) ? 8'hFF : $random(seed);
            pk_b[0] = 8'h80; pk_last[0] = 1'b0;
            for (i = 0; i <= npay; i = i + 1) begin pk_b[i+1] = exp_b[i]; pk_last[i+1] = (i == npay); end
            pk_n = npay + 2;
        end
    endtask

    integer G, LJK, LSE, GAP;
    integer n_pkt = 0;

    task set_speed(input [1:0] s);
        begin
            spd = s;
            G   = (s == 2'b10) ? 100 : 16;
            LJK = 16;
            LSE = (s == 2'b10) ? 124 : 24;
            GAP = (s == 2'b10) ? 6000 : 1500;
        end
    endtask

    // one packet; dir 1 = host -> device, 0 = device -> host
    task xfer(input integer dir, input integer npay);
        integer d0, de0, h0, he0, i;
        reg ok;
        begin
            skew = 2.0 * ({$random(seed)} % 3);
            repeat (50) @(posedge clk_bit);
            ls_start;
            d0 = dm_pk; de0 = dm_err; h0 = hm_pk; he0 = hm_err;
            make_pkt(npay);
            if (dir) begin @(negedge clk_far); h_idx = 0; end
            else     begin @(negedge clk_bit); d_idx = 0; end
            // wait for the end of the transmission, then the gap
            repeat (20) @(posedge clk_bit);
            while (d_idx < pk_n || h_idx < pk_n || d_busy || h_busy || d_act || h_act)
                @(posedge clk_bit);
            repeat (GAP) @(posedge clk_bit);
            d_idx = 64; h_idx = 64;                  // both feeders idle
            n_pkt = n_pkt + 1;
            // receiving end
            ok = 1;
            if (dir) begin
                if (dm_pk != d0 + 1 || dm_err != de0 || dm_n != exp_n) ok = 0;
                for (i = 0; i < exp_n && ok; i = i + 1) if (dm_b[i] != exp_b[i]) ok = 0;
                if (hm_pk != h0) begin errors = errors + 1; $display("ERROR @%0t: host received its own packet", $time); end
            end else begin
                if (hm_pk != h0 + 1 || hm_err != he0 || hm_n != exp_n) ok = 0;
                for (i = 0; i < exp_n && ok; i = i + 1) if (hm_b[i] != exp_b[i]) ok = 0;
                if (dm_pk != d0) begin errors = errors + 1; $display("ERROR @%0t: device received its own packet", $time); end
            end
            if (!ok) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s packet %0d (%0s, %0d bytes, skew %.0f ns) not received correctly (%0d / %0d bytes, err %0d)",
                         $time, (spd == 2'b10) ? "LS" : "FS", n_pkt, dir ? "host -> device" : "device -> host",
                         exp_n, skew, dir ? dm_n : hm_n, exp_n, dir ? dm_err - de0 : hm_err - he0);
            end
            ls_compare(dir ? "host -> device" : "device -> host", G, LJK, LSE, 1);
        end
    endtask

    // pull-up switch with LineState comparison (no EOP)
    task attach(input dp, input dm);
        begin
            ls_start;
            @(negedge clk_bit); pu_dp = dp; pu_dm = dm;
            repeat (GAP) @(posedge clk_bit);
            ls_compare(dp ? "FS attach" : dm ? "LS attach" : "detach", G, LJK, LSE, (dp || dm) ? 1 : 0);
        end
    endtask

    integer k;
    initial begin
        set_speed(2'b01);
        repeat (10) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (200) @(posedge clk_bit);

        // ---- FS ----
        attach(1'b1, 1'b0);
        if (ls !== 2'b01) begin errors = errors + 1; $display("ERROR: FS attach: LineState %b, expected J (01)", ls); end
        half_f = HALF * (1.0 + 1500.0e-6);
        for (k = 0; k < 16; k = k + 1)
            xfer(k % 2, (k < 2) ? k : {$random(seed)} % 25);
        half_f = HALF * (1.0 - 1500.0e-6);
        set_speed(2'b11);
        for (k = 0; k < 4; k = k + 1)
            xfer(k % 2, {$random(seed)} % 25);
        set_speed(2'b01);
        attach(1'b0, 1'b0);
        if (ls !== 2'b00) begin errors = errors + 1; $display("ERROR: detach: LineState %b, expected SE0", ls); end

        // ---- LS ----
        set_speed(2'b10);
        attach(1'b0, 1'b1);
        if (ls !== 2'b10) begin errors = errors + 1; $display("ERROR: LS attach: LineState %b, expected J (10)", ls); end
        half_f = HALF * (1.0 + 1500.0e-6);
        for (k = 0; k < 10; k = k + 1) begin
            if (k == 5) half_f = HALF * (1.0 - 1500.0e-6);
            xfer(k % 2, {$random(seed)} % 9);
        end
        attach(1'b0, 1'b0);
        if (ls !== 2'b00) begin errors = errors + 1; $display("ERROR: LS detach: LineState %b, expected SE0", ls); end

        $display("packets: %0d, LineState changes checked: %0d, worst latency J/K %0d, SE0/SE1 %0d cycles",
                 n_pkt, n_ls_chg, lat_max[0], lat_max[1]);
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
