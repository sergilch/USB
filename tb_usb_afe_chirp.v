//-----------------------------------------------------------------------------
// tb_usb_afe_chirp.v - attach, reset, HS handshake, HS traffic, disconnect,
//                      suspend / resume through the AFE models (phase A6)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_chirp usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_afe_tx_if.v usb_afe_rx_if.v \
//            usb_rx_nrzi_decoder.v usb_rx_sync_detect.v usb_rx_bit_unstuffer.v \
//            usb_rx_deserializer.v usb_rx_eop_check.v usb_rx_decoder.v \
//            usb_rx_elastic_buffer.v usb_rx_hs_frontend.v usb_rx_fsls_frontend.v \
//            usb_rx_datapath.v usb_rx_status_flt.v usb_rx_status_sync.v \
//            usb_line_state.v usb_mode_term_ctrl.v afe_line_bm.v afe_term_bm.v \
//            afe_hs_tx_bm.v afe_fsls_bm.v afe_hs_rx_bm.v afe_squelch_bm.v \
//            afe_cdr_bm.v tb_usb_afe_chirp.v
//   vvp sim_afe_chirp
//
// Set-up: two PHY ends (tb_chirp_end, below) on one DP / DM pair.  Each end is
// the RTL below the ULPI interface, with the AFE models:
//   registers (Function Control / OTG Control, written by the Link model here)
//     -> usb_mode_term_ctrl -> afe_term_bm (pull-up, 45 Ohm, pull-downs)
//   byte feeder -> usb_tx_path (bypass / eop_dis from usb_mode_term_ctrl)
//     -> usb_afe_tx_if (drv_dis) -> afe_hs_tx_bm + afe_fsls_bm
//   line -> afe_hs_rx_bm, afe_squelch_bm -> afe_cdr_bm -> usb_afe_rx_if
//        -> afe_fsls_bm receivers -> usb_rx_status_sync -> usb_line_state
//        -> usb_rx_datapath (HS_ZMIN 4, lock_dly 2: the recommended set-up)
//   The host end runs on a clock 400 ppm faster than the device.
//   SYNC insertion (usb_tx_sync_mux, tx_sync_dis) is upstream of usb_tx_path:
//   the feeders send SYNC bytes themselves in OpMode 00 and none in OpMode 10.
//
// The Link models follow ULPI 1.1 3.8.5 with the long USB timers scaled down
// (the PHY has no timers of its own in these sequences): chirp K 20 us (USB
// >= 1 ms), host chirps 5 us each (40-60 us), suspend idle 10 us (3 ms), resume
// K 20 us (20 ms).  The detection times are the real ones: SE0 2.5 us, each
// chirp 2.5 us.
//
// Sequence and checks
//   1. Attach: host FS (pull-downs), device FS peripheral (pull-up): host
//      LineState SE0 -> J.
//   2. Reset: host XcvrSelect 00 / TermSelect 0 / OpMode 10 (45 Ohm on): device
//      LineState SE0 within 1 us.
//   3. Device chirp K (XcvrSelect 00, TermSelect 1, OpMode 10, 00h bytes):
//      pull-up stays on; DM - DP 0.65-0.75 V (800 mV into the host's 45 Ohm,
//      minus the pull-up's 96 mV on DP); never a J on the line (no SYNC, no
//      EOP: DP - DM < +0.1 V from the start of the chirp until 200 ns after it);
//      host LineState (chirp encoding) SE0 -> K -> SE0.
//   4. Host chirps K J K J ... (8 pairs, 00h / FFh bytes, OpMode 10, no EOP),
//      starting 1 us after the K ended.  The device counts K-J-K-J-K-J on its
//      LineState (each >= 2.5 us), then goes HS (TermSelect 0, OpMode 00):
//      pull-up off before the 45 Ohm go on (never both); chirp amplitude then
//      |DP - DM| 0.36-0.44 V; device LineState !squelch (01) during the rest of
//      the chirps and squelch (00) within 1 us of their end.
//   5. HS traffic: 4 host -> device and 4 device -> host packets (SYNC + PID +
//      payload), each received intact by the other end and not by the sender;
//      host_disc stays 0.
//   6. Disconnect: device OpMode 01 (all its terminations off, like a detach):
//      the next host packet sets host_disc; device back to HS: the next packet
//      clears it.
//   7. Suspend: both FS (TermSelect 1): device 45 Ohm off before the pull-up
//      goes on; line J (DP > 2.8 V); LineState J at both ends.
//   8. Remote wake-up: device OpMode 10 FS K (00h bytes) for 10 us: a peripheral
//      sends no EOP, so host LineState goes K -> J without SE0.
//   9. Resume: host OpMode 10 FS K for 20 us; the host PHY appends the FS EOP
//      (host at FS): device LineState J -> K -> SE0 -> J with the SE0 lasting
//      2 FS bits (167 ns +- 40 ns).  Host goes HS (45 Ohm on): device sees SE0
//      and goes HS; HS traffic again (one packet each way).
//   Throughout: no false packet at either end, no TX underrun, the pull-up and
//   the HS terminations of an end never on together, a host never pulls up.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_afe_chirp;
    parameter real HALF = 1.0416667;
    parameter real PPM_H = 400.0;

    // scaled USB timers (ns)
    localparam real T_SE0_DET = 2500.0;
    localparam real T_CH_DET  = 2500.0;
    localparam real T_CHIRP_K = 20000.0;
    localparam real T_HCHIRP  = 5000.0;
    localparam      N_KJ      = 8;
    localparam real T_SUSP    = 10000.0;
    localparam real T_RESUME  = 20000.0;
    localparam real T_WAKE    = 10000.0;
    localparam real T_TICK    = 16.6666667;

    integer errors = 0;
    integer seed   = 32'h0C41_4B1D;

    reg clk_d = 1'b0, clk_h = 1'b0;
    always #(HALF) clk_d = ~clk_d;
    always #(HALF / (1.0 + PPM_H * 1.0e-6)) clk_h = ~clk_h;
    reg rst_n = 1'b0;

    wire [63:0] dp_v, dm_v;
    wire [63:0] d_tdpg, d_tdpi, d_tdmg, d_tdmi, d_hdpg, d_hdpi, d_hdmg, d_hdmi, d_fdpg, d_fdpi, d_fdmg, d_fdmi;
    wire [63:0] h_tdpg, h_tdpi, h_tdmg, h_tdmi, h_hdpg, h_hdpi, h_hdmg, h_hdmi, h_fdpg, h_fdpi, h_fdmg, h_fdmi;

    tb_chirp_end #(.HOST(0), .SEED(21)) dev (
        .clk(clk_d), .rst_n(rst_n), .dp_v(dp_v), .dm_v(dm_v),
        .t_dpg(d_tdpg), .t_dpi(d_tdpi), .t_dmg(d_tdmg), .t_dmi(d_tdmi),
        .h_dpg(d_hdpg), .h_dpi(d_hdpi), .h_dmg(d_hdmg), .h_dmi(d_hdmi),
        .f_dpg(d_fdpg), .f_dpi(d_fdpi), .f_dmg(d_fdmg), .f_dmi(d_fdmi));
    tb_chirp_end #(.HOST(1), .SEED(37)) host (
        .clk(clk_h), .rst_n(rst_n), .dp_v(dp_v), .dm_v(dm_v),
        .t_dpg(h_tdpg), .t_dpi(h_tdpi), .t_dmg(h_tdmg), .t_dmi(h_tdmi),
        .h_dpg(h_hdpg), .h_dpi(h_hdpi), .h_dmg(h_hdmg), .h_dmi(h_hdmi),
        .f_dpg(h_fdpg), .f_dpi(h_fdpi), .f_dmg(h_fdmg), .f_dmi(h_fdmi));

    afe_line_bm u_line (
        .dp_g0(d_tdpg), .dp_i0(d_tdpi), .dp_g1(d_hdpg), .dp_i1(d_hdpi),
        .dp_g2(d_fdpg), .dp_i2(d_fdpi), .dp_g3(h_tdpg), .dp_i3(h_tdpi),
        .dp_g4(h_hdpg), .dp_i4(h_hdpi), .dp_g5(h_fdpg), .dp_i5(h_fdpi),
        .dm_g0(d_tdmg), .dm_i0(d_tdmi), .dm_g1(d_hdmg), .dm_i1(d_hdmi),
        .dm_g2(d_fdmg), .dm_i2(d_fdmi), .dm_g3(h_tdmg), .dm_i3(h_tdmi),
        .dm_g4(h_hdmg), .dm_i4(h_hdmi), .dm_g5(h_fdmg), .dm_i5(h_fdmi),
        .dp_v(dp_v), .dm_v(dm_v));

    initial begin
        $dumpfile("tb_usb_afe_chirp.vcd");
        $dumpvars(0, tb_usb_afe_chirp);
    end

    real vp, vm;
    always @(dp_v or dm_v) begin vp = $bitstoreal(dp_v); vm = $bitstoreal(dm_v); end

    // ---------------- continuous checks ----------------
    reg no_j = 1'b0;                              // window: the line must not show J
    reg rx_quiet = 1'b1;                          // no packet may arrive
    always @(posedge clk_d) begin
        if (dev.pu_dp && dev.hs_term) begin
            errors = errors + 1; $display("ERROR @%0t: device pull-up and HS termination on together", $time);
        end
        if (host.pu_dp || host.pu_dm) begin
            errors = errors + 1; $display("ERROR @%0t: host pull-up on", $time);
        end
        if (no_j && (vp - vm > 0.1)) begin
            errors = errors + 1; $display("ERROR @%0t: J on the line during the device chirp (DP - DM %.3f V)", $time, vp - vm);
            no_j = 1'b0;
        end
    end

    // ---------------- helpers ----------------
    task wait_ns(input real t); begin #(t); end endtask

    // wait until a LineState holds value v for t ns (timeout tmo ns)
    task wait_ls(input integer is_host, input [1:0] v, input real t, input real tmo,
                 input [8*40-1:0] what);
        real t0, ts;
        reg  ok;
        begin
            t0 = $realtime; ts = -1.0; ok = 0;
            while (!ok && ($realtime - t0 < tmo)) begin
                @(posedge clk_d);
                if ((is_host ? host.ls : dev.ls) == v) begin
                    if (ts < 0) ts = $realtime;
                    if ($realtime - ts >= t) ok = 1;
                end else ts = -1.0;
            end
            if (!ok) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: %0s LineState never %b for %.0f ns (now %b)", $time, what,
                         is_host ? "host" : "device", v, t, is_host ? host.ls : dev.ls);
            end
        end
    endtask

    // record the distinct LineState values of one end for a time
    reg [1:0] seq [0:63];
    real      seq_t [0:63];
    integer   seq_n;
    task record_ls(input integer is_host, input real t);
        real t0;
        reg [1:0] cur;
        begin
            t0 = $realtime; cur = is_host ? host.ls : dev.ls;
            seq_n = 1; seq[0] = cur; seq_t[0] = t0;
            while ($realtime - t0 < t) begin
                @(posedge clk_d);
                if ((is_host ? host.ls : dev.ls) != cur) begin
                    cur = is_host ? host.ls : dev.ls;
                    if (seq_n < 64) begin seq[seq_n] = cur; seq_t[seq_n] = $realtime; seq_n = seq_n + 1; end
                end
            end
        end
    endtask

    task show_seq(input [8*40-1:0] what);
        integer i;
        begin
            $display("   %0s:", what);
            for (i = 0; i < seq_n && i < 12; i = i + 1)
                $display("     %b @ %.1f us", seq[i], seq_t[i] / 1000.0);
        end
    endtask

    task check_amp(input [8*40-1:0] what, input real lo, input real hi, input real sign);
        real d;
        begin
            d = sign * (vp - vm);
            if (d < lo || d > hi) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: DP - DM = %.3f V, expected %.2f-%.2f V (sign %0.0f)",
                         $time, what, vp - vm, lo, hi, sign);
            end
        end
    endtask

    // one HS packet from one end to the other
    integer pk_n = 0;
    task hs_packet(input integer from_host, input integer npay);
        integer d0, h0, i, de0, he0;
        reg ok;
        begin
            d0 = dev.rm_pk; h0 = host.rm_pk; de0 = dev.rm_err; he0 = host.rm_err;
            if (from_host) host.load_pkt(npay); else dev.load_pkt(npay);
            if (from_host) host.go; else dev.go;
            if (from_host) host.wait_tx; else dev.wait_tx;
            #(2000);
            pk_n = pk_n + 1;
            ok = 1;
            if (from_host) begin
                if (dev.rm_pk != d0 + 1 || dev.rm_err != de0 || dev.rm_n != host.exp_n) ok = 0;
                for (i = 0; i < host.exp_n && ok; i = i + 1) if (dev.rm_b[i] != host.exp_b[i]) ok = 0;
                if (host.rm_pk != h0) begin errors = errors + 1; $display("ERROR @%0t: host received its own packet", $time); end
            end else begin
                if (host.rm_pk != h0 + 1 || host.rm_err != he0 || host.rm_n != dev.exp_n) ok = 0;
                for (i = 0; i < dev.exp_n && ok; i = i + 1) if (host.rm_b[i] != dev.exp_b[i]) ok = 0;
                if (dev.rm_pk != d0) begin errors = errors + 1; $display("ERROR @%0t: device received its own packet", $time); end
            end
            if (!ok) begin
                errors = errors + 1;
                $display("ERROR @%0t: HS packet %0d %0s (%0d bytes) not received intact",
                         $time, pk_n, from_host ? "host -> device" : "device -> host",
                         from_host ? host.exp_n : dev.exp_n);
            end
        end
    endtask

    // HS packet from the host with no receiver check (disconnect step)
    task hs_packet_nochk(input integer npay);
        begin host.load_pkt(npay); host.go; host.wait_tx; #(500); end
    endtask

    integer rx_d0, rx_h0;
    task quiet_start; begin rx_d0 = dev.rm_pk + dev.rm_start_n; rx_h0 = host.rm_pk + host.rm_start_n; end endtask
    task quiet_check(input [8*40-1:0] what);
        begin
            if (dev.rm_pk + dev.rm_start_n != rx_d0 || host.rm_pk + host.rm_start_n != rx_h0) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: a packet was received (device %0d, host %0d)", $time, what,
                         dev.rm_pk + dev.rm_start_n - rx_d0, host.rm_pk + host.rm_start_n - rx_h0);
            end
        end
    endtask

    // ---------------- sequence ----------------
    real    t_k_end, t_se0, t_sw, t_hend;
    integer i, cnt, k;
    reg [1:0] cur, expv;
    real    t_cur;
    initial begin
        // register defaults: power-up row (FS, pull-downs on)
        dev.set_regs (2'b01, 1'b0, 2'b00, 1'b1, 1'b1);
        host.set_regs(2'b01, 1'b0, 2'b00, 1'b1, 1'b1);
        #(50);
        rst_n = 1'b1;
        #(500);

        // ---- 1. attach ----
        $display("1. attach");
        host.set_regs(2'b01, 1'b1, 2'b00, 1'b1, 1'b1);      // host FS
        #(1000);
        if (host.ls !== 2'b00) begin errors = errors + 1; $display("ERROR: host LineState %b before attach, expected SE0", host.ls); end
        dev.set_regs(2'b01, 1'b1, 2'b00, 1'b0, 1'b0);       // FS peripheral: pull-up on
        wait_ls(1, 2'b01, 500.0, 2000.0, "attach");
        quiet_start;

        // ---- 2. reset ----
        $display("2. reset (host 45 Ohm -> SE0)");
        #(T_CH_DET);
        host.set_regs(2'b00, 1'b0, 2'b10, 1'b1, 1'b1);      // host chirp: 45 Ohm on
        t_se0 = $realtime;
        wait_ls(0, 2'b00, 10.0, 1000.0, "reset");
        // ---- 3. device chirp K ----
        wait_ls(0, 2'b00, T_SE0_DET, T_SE0_DET + 2000.0, "reset detection");
        $display("3. device chirp K (%.1f us after reset start)", ($realtime - t_se0) / 1000.0);
        dev.set_regs(2'b00, 1'b1, 2'b10, 1'b0, 1'b0);       // peripheral chirp
        #(4 * T_TICK);
        if (!dev.pu_dp || dev.hs_term) begin errors = errors + 1; $display("ERROR: chirp: device pull-up %b, HS termination %b", dev.pu_dp, dev.hs_term); end
        no_j = 1'b1;
        dev.load_pattern(T_CHIRP_K / T_TICK, 0);             // 00h bytes = chirp K
        dev.go;
        fork
            begin
                #(T_CHIRP_K / 2);
                check_amp("device chirp K", 0.65, 0.75, -1.0);
            end
            begin
                // host Link: K detected for T_CH_DET, then wait for its end
                wait_ls(1, 2'b10, T_CH_DET, T_CHIRP_K, "device chirp K at the host");
                while (host.ls == 2'b10) @(posedge clk_d);
                t_k_end = $realtime;
            end
        join
        dev.wait_tx;
        #(200);
        no_j = 1'b0;
        if (host.ls !== 2'b00) begin errors = errors + 1; $display("ERROR: host LineState %b after the chirp K, expected SE0", host.ls); end

        // ---- 4. host chirps ----
        $display("4. host chirps K J x %0d", N_KJ);
        if ($realtime - t_k_end < 1000.0) wait_ns(1000.0 - ($realtime - t_k_end));
        host.load_pattern(2 * N_KJ * (T_HCHIRP / T_TICK), T_HCHIRP / T_TICK);
        host.go;
        // device Link: K-J-K-J-K-J, each >= T_CH_DET
        cnt = 0; expv = 2'b10; cur = dev.ls; t_cur = $realtime;
        while (cnt < 6) begin
            @(posedge clk_d);
            if (dev.ls != cur) begin
                if (cur == expv && ($realtime - t_cur >= T_CH_DET)) begin cnt = cnt + 1; expv = ~expv; end
                else if (cur != 2'b00) cnt = 0;
                cur = dev.ls; t_cur = $realtime;
            end
            if ($realtime - t_k_end > 2 * N_KJ * T_HCHIRP + 5000.0) begin
                errors = errors + 1; $display("ERROR @%0t: device never counted K-J-K-J-K-J (count %0d)", $time, cnt);
                cnt = 6;
            end
        end
        dev.set_regs(2'b00, 1'b0, 2'b00, 1'b0, 1'b0);       // HS: pull-up off, 45 Ohm on
        t_sw = $realtime;
        $display("   device in HS mode %.1f us after the first host chirp", (t_sw - t_k_end - 1000.0) / 1000.0);
        // middle of the next full chirp
        #(1.5 * T_HCHIRP);
        check_amp("host chirp with HS terminations at both ends", 0.36, 0.44, (vp > vm) ? 1.0 : -1.0);
        if (dev.ls !== 2'b01) begin errors = errors + 1; $display("ERROR: device LineState %b during chirps in HS mode, expected !squelch (01)", dev.ls); end
        host.wait_tx;
        t_hend = $realtime;
        host.set_regs(2'b00, 1'b0, 2'b00, 1'b1, 1'b1);      // host HS
        wait_ls(0, 2'b00, 10.0, 1000.0, "squelch after the host chirps");
        quiet_check("handshake");

        // ---- 5. HS traffic ----
        $display("5. HS traffic");
        #(1000);
        for (k = 0; k < 8; k = k + 1) begin
            hs_packet(k % 2 == 0, (k == 0) ? 2 : {$random(seed)} % 33);
            if (host.hd !== 1'b0) begin errors = errors + 1; $display("ERROR @%0t: host_disc set with the device attached", $time); end
        end

        // ---- 6. disconnect ----
        $display("6. disconnect");
        dev.set_regs(2'b00, 1'b0, 2'b01, 1'b0, 1'b0);       // non-driving: terminations off
        #(10 * T_TICK);
        if (dev.pu_dp || dev.hs_term) begin errors = errors + 1; $display("ERROR: OpMode 01: device terminations not off"); end
        hs_packet_nochk(2);
        if (host.hd !== 1'b1) begin errors = errors + 1; $display("ERROR @%0t: host_disc not set after a packet into an open line", $time); end
        dev.set_regs(2'b00, 1'b0, 2'b00, 1'b0, 1'b0);       // back
        #(10 * T_TICK);
        hs_packet(1, 2);
        if (host.hd !== 1'b0) begin errors = errors + 1; $display("ERROR @%0t: host_disc not cleared after the device came back", $time); end
        quiet_start;

        // ---- 7. suspend ----
        $display("7. suspend (FS)");
        #(T_SUSP);
        dev.set_regs (2'b01, 1'b1, 2'b00, 1'b0, 1'b0);      // device FS: 45 Ohm off, then pull-up
        host.set_regs(2'b01, 1'b1, 2'b00, 1'b1, 1'b1);      // host FS: 45 Ohm off
        #(1000);
        if (vp < 2.8 || vm > 0.3) begin errors = errors + 1; $display("ERROR: suspend: line DP %.2f V DM %.2f V, expected FS J", vp, vm); end
        if (dev.ls !== 2'b01 || host.ls !== 2'b01) begin
            errors = errors + 1; $display("ERROR: suspend: LineState device %b host %b, expected J", dev.ls, host.ls);
        end

        // ---- 8. remote wake-up K (peripheral: no EOP) ----
        $display("8. remote wake-up K");
        #(T_SUSP);
        dev.set_regs(2'b01, 1'b1, 2'b10, 1'b0, 1'b0);       // peripheral resume (OpMode 10)
        dev.load_pattern(T_WAKE / 666.667, 0);               // FS byte = 8 bits = 667 ns
        dev.go;
        fork
            dev.wait_tx;
            record_ls(1, T_WAKE + 3000.0);
        join
        show_seq("host LineState, remote wake-up");
        if (!(seq_n == 3 && seq[0] == 2'b01 && seq[1] == 2'b10 && seq[2] == 2'b01)) begin
            errors = errors + 1; $display("ERROR: remote wake-up: host LineState must be J -> K -> J (no EOP)");
        end
        dev.set_regs(2'b01, 1'b1, 2'b00, 1'b0, 1'b0);

        // ---- 9. host resume K with EOP, back to HS ----
        $display("9. host resume K");
        host.set_regs(2'b01, 1'b1, 2'b10, 1'b1, 1'b1);      // host resume
        host.load_pattern(T_RESUME / 666.667, 0);
        host.go;
        fork
            host.wait_tx;
            record_ls(0, T_RESUME + 3000.0);
        join
        show_seq("device LineState, resume");
        if (!(seq_n == 4 && seq[0] == 2'b01 && seq[1] == 2'b10 && seq[2] == 2'b00 && seq[3] == 2'b01)) begin
            errors = errors + 1; $display("ERROR: resume: device LineState must be J -> K -> SE0 -> J");
        end else if ((seq_t[3] - seq_t[2]) < 127.0 || (seq_t[3] - seq_t[2]) > 207.0) begin
            errors = errors + 1; $display("ERROR: resume EOP: SE0 for %.0f ns, expected 2 FS bits (167 ns)", seq_t[3] - seq_t[2]);
        end
        host.set_regs(2'b00, 1'b0, 2'b00, 1'b1, 1'b1);      // host HS: 45 Ohm -> SE0
        wait_ls(0, 2'b00, 100.0, 2000.0, "SE0 after resume");
        dev.set_regs(2'b00, 1'b0, 2'b00, 1'b0, 1'b0);       // device HS
        #(1000);
        quiet_check("suspend / resume");
        hs_packet(1, 8);
        hs_packet(0, 8);

        errors = errors + dev.errors + host.errors;
        $display("HS packets: %0d", pk_n);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule

//-----------------------------------------------------------------------------
// tb_chirp_end: one end of the line (device or host), the PHY below ULPI with
// its AFE models, plus a register set, a byte feeder and a receive monitor that
// the Link model above drives through hierarchical references.
//-----------------------------------------------------------------------------
module tb_chirp_end #(
    parameter HOST = 0,
    parameter SEED = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] dp_v, dm_v,
    output wire [63:0] t_dpg, t_dpi, t_dmg, t_dmi,     // terminations
    output wire [63:0] h_dpg, h_dpi, h_dmg, h_dmi,     // HS driver
    output wire [63:0] f_dpg, f_dpi, f_dmg, f_dmi      // FS / LS driver
);
    integer errors = 0;
    integer seed = SEED;

    reg [2:0] ce_cnt = 3'd0;
    wire ce60 = (ce_cnt == 3'd7);
    always @(posedge clk) ce_cnt <= ce_cnt + 3'd1;

    // ---------------- registers (Function Control, OTG Control) ----------------
    reg [1:0] xs = 2'b01, om = 2'b00;
    reg       ts = 1'b0, dpd = 1'b1, dmd = 1'b1;
    task set_regs(input [1:0] x, input t, input [1:0] m, input pdp, input pdm);
        begin
            @(negedge clk);
            xs = x; ts = t; om = m; dpd = pdp; dmd = pdm;
        end
    endtask

    wire pu_dp, pu_dm, hs_term, pd_dp, pd_dm, t_busy, byp, sdis, edis, ddis, hmode;
    usb_mode_term_ctrl u_mode (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60),
        .xcvrselect(xs), .termselect(ts), .opmode(om), .dp_pulldown(dpd), .dm_pulldown(dmd),
        .iso_en(1'b0),
        .dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(hs_term),
        .dp_pulldown_en(pd_dp), .dm_pulldown_en(pd_dm), .term_busy(t_busy),
        .tx_bypass(byp), .tx_sync_dis(sdis), .tx_eop_dis(edis), .drv_dis(ddis), .host_mode(hmode));

    // ---------------- byte feeder ----------------
    reg  [7:0] fb [0:63];
    integer    f_n = 0, f_idx = 1 << 30, f_per = 0;
    reg        f_pat = 1'b0;
    reg        in_valid = 1'b0, in_last = 1'b0;
    reg  [7:0] in_data = 8'd0;
    wire       in_ready;
    reg  [7:0] exp_b [0:63];
    integer    exp_n = 0;
    reg [7:0] pids [0:7];
    initial begin
        pids[0] = 8'hA5; pids[1] = 8'hC3; pids[2] = 8'h4B; pids[3] = 8'hD2;
        pids[4] = 8'h69; pids[5] = 8'hE1; pids[6] = 8'h2D; pids[7] = 8'h87;
    end

    function [7:0] fbyte(input integer i);
        begin
            if (!f_pat)            fbyte = fb[i];
            else if (f_per == 0)   fbyte = 8'h00;
            else                   fbyte = ((i / f_per) % 2) ? 8'hFF : 8'h00;
        end
    endfunction

    always @(posedge clk) if (rst_n && ce60) begin
        if (in_valid && in_ready) f_idx = f_idx + 1;
        if (f_idx < f_n) begin in_valid <= 1'b1; in_data <= fbyte(f_idx); in_last <= (f_idx == f_n - 1); end
        else in_valid <= 1'b0;
    end

    // SYNC + PID + payload
    task load_pkt(input integer npay);
        integer i;
        begin
            f_idx = 1 << 30; f_pat = 1'b0;
            exp_n = npay + 1;
            exp_b[0] = pids[{$random(seed)} % 8];
            for (i = 1; i <= npay; i = i + 1) exp_b[i] = ({$random(seed)} % 4 == 0) ? 8'hFF : $random(seed);
            fb[0] = 8'h00; fb[1] = 8'h00; fb[2] = 8'h00; fb[3] = 8'h80;
            for (i = 0; i <= npay; i = i + 1) fb[4 + i] = exp_b[i];
            f_n = npay + 5;
        end
    endtask

    // OpMode 10 signalling: n bytes of 00h (per = 0) or alternating 00h / FFh runs
    task load_pattern(input integer n, input integer per);
        begin f_idx = 1 << 30; f_pat = 1'b1; f_per = per; f_n = n; end
    endtask

    task go; begin @(negedge clk); f_idx = 0; end endtask

    task wait_tx;
        begin
            @(posedge clk);
            while (f_idx < f_n || tx_busy || tx_act) @(posedge clk);
            f_idx = 1 << 30;
        end
    endtask

    // ---------------- TX ----------------
    wire txd, tx_en, tx_se0, tx_busy, tx_done, tx_under;
    wire [1:0] tx_spd;
    wire hs_p, hs_n, hs_en, fs_oe, fs_dat, fs_se0, fs_ls, tx_act;

    usb_tx_path u_tx (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60), .speed(xs), .bypass_en(byp), .eop_dis(edis),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data), .in_last(in_last),
        .txd(txd), .tx_en(tx_en), .tx_se0(tx_se0), .tx_speed(tx_spd),
        .busy(tx_busy), .tx_done(tx_done), .tx_underrun(tx_under));
    usb_afe_tx_if u_afe_tx (
        .clk_bit(clk), .rst_n(rst_n),
        .txd(txd), .tx_en(tx_en), .tx_se0(tx_se0), .tx_speed(tx_spd),
        .tx_lead(5'd10), .tx_lag(3'd0), .drv_dis(ddis), .iso_en(1'b0), .lead_first(byp),
        .hs_tx_p(hs_p), .hs_tx_n(hs_n), .hs_tx_en(hs_en),
        .fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls), .tx_active(tx_act));
    always @(posedge clk) if (tx_under) begin
        errors = errors + 1; $display("ERROR @%0t: %0s TX underrun", $time, HOST ? "host" : "device");
    end

    // ---------------- analog models ----------------
    wire hx_settled;
    wire [31:0] skew_err;
    wire rxdp_a, rxdm_a, rxrcv_a;
    afe_term_bm u_term (.dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(hs_term),
                        .dp_pulldown_en(pd_dp), .dm_pulldown_en(pd_dm),
                        .dp_g(t_dpg), .dp_i(t_dpi), .dm_g(t_dmg), .dm_i(t_dmi));
    afe_hs_tx_bm u_hstx (.TX_IN_P(hs_p), .TX_IN_N(hs_n), .TX_EN(hs_en),
                         .dp_g(h_dpg), .dp_i(h_dpi), .dm_g(h_dmg), .dm_i(h_dmi),
                         .settled(hx_settled), .skew_err(skew_err));
    afe_fsls_bm u_fsls (.fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls),
                        .dp_g(f_dpg), .dp_i(f_dpi), .dm_g(f_dmg), .dm_i(f_dmi),
                        .rx_en(1'b1), .dp_v(dp_v), .dm_v(dm_v),
                        .rxdp(rxdp_a), .rxdm(rxdm_a), .rxrcv(rxrcv_a));

    wire rx_en_hs, cdr_en, rx_p, rx_n, squelch_a, disc_a, clk_rx, cdr_d;
    wire [31:0] c_up, c_dn, c_bits;
    afe_hs_rx_bm   #(.SEED(SEED)) u_hsrx (.dp_v(dp_v), .dm_v(dm_v), .RX_EN(rx_en_hs), .RX_OUT_P(rx_p), .RX_OUT_N(rx_n));
    afe_squelch_bm u_sq (.dp_v(dp_v), .dm_v(dm_v), .en(rx_en_hs), .squelch(squelch_a), .disc(disc_a));
    afe_cdr_bm     #(.SEED(SEED + 1)) u_cdr (.CDR_DATA(rx_p), .CDR_EN(cdr_en), .clk_rx(clk_rx), .hs_rxd(cdr_d),
                                             .n_up(c_up), .n_dn(c_dn), .n_bits(c_bits));

    // ---------------- receive side ----------------
    wire hs_rxd, hs_sq, hs_lock;
    usb_afe_rx_if u_afe_rx (
        .clk_bit(clk), .rst_n(rst_n), .speed(xs), .rx_en(1'b1), .iso_en(1'b0),
        .lock_dly(3'd2), .sq_comp(3'd0), .rx_en_hs(rx_en_hs), .cdr_en(cdr_en),
        .clk_rx(clk_rx), .hs_rxd_a(cdr_d), .squelch_a(squelch_a),
        .hs_rxd(hs_rxd), .hs_squelch(hs_sq), .hs_cdr_lock(hs_lock));

    wire s_dp, s_dm, s_rcv, s_sq, s_disc, s_avv, s_sv, s_se, s_id;
    usb_rx_status_sync u_ss (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60),
        .rxdp(rxdp_a), .rxdm(rxdm_a), .rxrcv(rxrcv_a), .squelch(squelch_a), .disc(disc_a),
        .a_vbus_vld(1'b1), .sess_vld(1'b1), .sess_end(1'b0), .id_gnd(1'b0),
        .sq_flt(4'd2), .disc_flt(4'd2), .vb_flt(16'd0),
        .rxdp_s(s_dp), .rxdm_s(s_dm), .rxrcv_s(s_rcv), .squelch_s(s_sq), .disc_s(s_disc),
        .a_vbus_vld_s(s_avv), .sess_vld_s(s_sv), .sess_end_s(s_se), .id_gnd_s(s_id));

    wire [1:0] ls;
    wire       hd;
    usb_line_state u_ls (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60),
        .rxdp_s(s_dp), .rxdm_s(s_dm), .rxrcv_s(s_rcv), .squelch_s(s_sq), .disc_s(s_disc),
        .xcvrselect(xs), .opmode(om), .host_mode(hmode), .hs_tx_act(tx_act),
        .linestate(ls), .host_disc(hd));

    wire       r_start, r_valid, r_end, r_error, r_busy;
    wire [7:0] r_data;
    usb_rx_datapath #(.HS_ZMIN(4)) u_rx (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60), .speed(xs), .rx_en(1'b1), .tx_en(tx_act),
        .clk_rx(clk_rx), .hs_rxd(hs_rxd), .hs_squelch(hs_sq), .hs_cdr_lock(hs_lock),
        .rxrcv(s_rcv), .rxdp(s_dp), .rxdm(s_dm),
        .rx_start(r_start), .rx_valid(r_valid), .rx_data(r_data), .rx_end(r_end),
        .rx_error(r_error), .rx_busy(r_busy));

    // ---------------- receive monitor ----------------
    reg  [7:0] rm_b [0:63];
    integer    rm_n = 0, rm_pk = 0, rm_err = 0, rm_start_n = 0;
    reg        rm_in = 1'b0;
    always @(posedge clk) if (rst_n && ce60) begin
        if (r_start + r_valid + r_end > 1) begin errors = errors + 1; $display("ERROR @%0t: %0s RX: two events in one tick", $time, HOST ? "host" : "device"); end
        if (r_start) begin
            if (rm_in) begin errors = errors + 1; $display("ERROR @%0t: %0s RX: start inside a packet", $time, HOST ? "host" : "device"); end
            rm_in = 1'b1; rm_n = 0; rm_start_n = rm_start_n + 1;
        end
        if (r_valid) begin
            if (!rm_in) begin errors = errors + 1; $display("ERROR @%0t: %0s RX: byte outside a packet", $time, HOST ? "host" : "device"); end
            else if (rm_n < 64) begin rm_b[rm_n] = r_data; rm_n = rm_n + 1; end
        end
        if (r_end) begin
            if (!rm_in) begin errors = errors + 1; $display("ERROR @%0t: %0s RX: end outside a packet", $time, HOST ? "host" : "device"); end
            rm_in = 1'b0; rm_pk = rm_pk + 1; rm_start_n = rm_start_n - 1;
            if (r_error) rm_err = rm_err + 1;
        end
    end
endmodule
