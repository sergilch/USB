//-----------------------------------------------------------------------------
// ams_link_seq.vh - Link models, sequence and checks of the two-ended line
//                   test; included in the body of the top module
//
// Included by AFE/ams/tb_ams_link.vams (Spectre AMS, Verilog-A AFE models) and
// tb_ams_link_shadow.v (Icarus, afe_*_bm.v models).  The including module
// provides:
//   reg  clk_d, rst_n         device clk_bit (the checks run on it), reset
//   ams_phy_end dev, host     the two ends (HOST = 0 / 1)
//   `AMS_VDP, `AMS_VDM        line voltages DP / DM in volts (a real expression)
// and may define before the include (defaults below, ns):
//   AMS_NPKT                  HS packets per direction (3)
//   AMS_NFS                   FS packets per direction (2)
//
// The USB timers are scaled down as in tb_usb_afe_chirp (the PHY has no timers
// of its own here), shorter still to keep the analog run short: chirp K 8 us
// (USB >= 1 ms), host chirps 3 us (40-60 us), 4 K-J pairs.  The detection
// times stay real: SE0 2.5 us, each chirp 2.5 us.
//
// Sequence and checks
//   1. Attach: host FS (pull-downs), device FS peripheral (pull-up): host
//      LineState SE0 -> J; line J (DP > 2.8 V, DM < 0.3 V).
//   2. FS traffic: AMS_NFS packets each way (SYNC + PID + 6 bytes), each
//      received intact by the far end and not by the sender.
//   3. Reset: host 45 Ohm on (XcvrSelect 00, OpMode 10): device LineState SE0.
//   4. Device chirp K (00h bytes, OpMode 10, pull-up still on): DM - DP
//      0.65-0.75 V, no J on the line from the start of the chirp until 200 ns
//      after it, host LineState K for >= 2.5 us.
//   5. Host chirps K-J: the device counts K-J-K-J-K-J (each >= 2.5 us), goes HS
//      (pull-up off before the 45 Ohm on); |DP - DM| 0.36-0.44 V; the host goes
//      HS after its chirps; device LineState squelch (00) within 1 us.
//   6. HS traffic: AMS_NPKT packets each way, intact, not received by the
//      sender; host_disc stays 0.
//   Throughout: no TX underrun, no false packet; the pull-up and the 45 Ohm of
//   an end never on together; a host never pulls up.
//-----------------------------------------------------------------------------

`ifndef AMS_NPKT
 `define AMS_NPKT 3
`endif
`ifndef AMS_NFS
 `define AMS_NFS 2
`endif

    localparam real T_SE0_DET = 2500.0;
    localparam real T_CH_DET  = 2500.0;
    localparam real T_CHIRP_K = 8000.0;
    localparam real T_HCHIRP  = 3000.0;
    localparam      N_KJ      = 4;
    localparam real T_TICK    = 16.6666667;

    integer errors = 0;
    integer seed   = 32'h0A3_5EED;

    // ---------------- continuous checks ----------------
    reg no_j = 1'b0;
    always @(posedge clk_d) begin
        if (dev.dp_pullup_en && dev.hs_term_en) begin
            errors = errors + 1; $display("ERROR @%0t: device pull-up and HS termination on together", $time);
        end
        if (host.dp_pullup_en || host.dm_pullup_en) begin
            errors = errors + 1; $display("ERROR @%0t: host pull-up on", $time);
        end
        if (no_j) begin
            if (`AMS_VDP - `AMS_VDM > 0.1) begin
                errors = errors + 1;
                $display("ERROR @%0t: J on the line during the device chirp (DP - DM %.3f V)", $time, `AMS_VDP - `AMS_VDM);
                no_j = 1'b0;
            end
        end
    end

    // ---------------- helpers ----------------
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

    task check_amp(input [8*40-1:0] what, input real lo, input real hi, input real sign);
        real vp, vm, d;
        begin
            vp = `AMS_VDP; vm = `AMS_VDM;
            d = sign * (vp - vm);
            if (d < lo || d > hi) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s: DP - DM = %.3f V, expected %.2f-%.2f V (sign %0.0f)",
                         $time, what, vp - vm, lo, hi, sign);
            end else
                $display("   %0s: |DP - DM| = %.3f V (DP %.3f, DM %.3f)", what, d, vp, vm);
        end
    endtask

    // one packet from one end to the other, at the current speed
    integer pk_n = 0;
    task packet(input integer from_host, input integer npay, input [8*8-1:0] what);
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
                $display("ERROR @%0t: %0s packet %0d %0s (%0d bytes) not received intact",
                         $time, what, pk_n, from_host ? "host -> device" : "device -> host",
                         from_host ? host.exp_n : dev.exp_n);
            end
        end
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
    real    t_k_end, t_sw, vdp, vdm;
    integer i, cnt, k, n_hs, n_fs;
    reg [1:0] cur, expv;
    real    t_cur;
    initial begin
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
        vdp = `AMS_VDP; vdm = `AMS_VDM;
        $display("   line J: DP %.3f V, DM %.3f V", vdp, vdm);
        if (vdp < 2.8 || vdm > 0.3) begin errors = errors + 1; $display("ERROR: attach: line not FS J"); end

        // ---- 2. FS traffic ----
        $display("2. FS traffic, %0d packets each way", `AMS_NFS);
        n_fs = `AMS_NFS;
        for (k = 0; k < 2 * n_fs; k = k + 1) packet(k % 2, 6, "FS");
        quiet_start;

        // ---- 3. reset ----
        $display("3. reset (host 45 Ohm -> SE0)");
        host.set_regs(2'b00, 1'b0, 2'b10, 1'b1, 1'b1);
        wait_ls(0, 2'b00, T_SE0_DET, T_SE0_DET + 2000.0, "reset detection");

        // ---- 4. device chirp K ----
        $display("4. device chirp K");
        dev.set_regs(2'b00, 1'b1, 2'b10, 1'b0, 1'b0);
        #(4 * T_TICK);
        no_j = 1'b1;
        dev.load_pattern(T_CHIRP_K / T_TICK, 0);
        dev.go;
        fork
            begin
                #(T_CHIRP_K / 2);
                check_amp("device chirp K", 0.65, 0.75, -1.0);
            end
            begin
                wait_ls(1, 2'b10, T_CH_DET, T_CHIRP_K, "device chirp K at the host");
                while (host.ls == 2'b10) @(posedge clk_d);
                t_k_end = $realtime;
            end
        join
        dev.wait_tx;
        #(200);
        no_j = 1'b0;

        // ---- 5. host chirps ----
        $display("5. host chirps K J x %0d", N_KJ);
        if ($realtime - t_k_end < 1000.0) #(1000.0 - ($realtime - t_k_end));
        host.load_pattern(2 * N_KJ * (T_HCHIRP / T_TICK), T_HCHIRP / T_TICK);
        host.go;
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
        dev.set_regs(2'b00, 1'b0, 2'b00, 1'b0, 1'b0);       // device HS
        t_sw = $realtime;
        #(T_HCHIRP / 2);
        vdp = `AMS_VDP; vdm = `AMS_VDM;
        check_amp("host chirp, 45 Ohm at both ends", 0.36, 0.44, (vdp > vdm) ? 1.0 : -1.0);
        host.wait_tx;
        host.set_regs(2'b00, 1'b0, 2'b00, 1'b1, 1'b1);      // host HS
        wait_ls(0, 2'b00, 10.0, 1000.0, "squelch after the host chirps");
        quiet_check("handshake");

        // ---- 6. HS traffic ----
        $display("6. HS traffic, %0d packets each way", `AMS_NPKT);
        #(1000);
        n_hs = `AMS_NPKT;
        for (k = 0; k < 2 * n_hs; k = k + 1) begin
            packet(k % 2 == 0, (k == 0) ? 2 : {$random(seed)} % 33, "HS");
            if (host.hd !== 1'b0) begin errors = errors + 1; $display("ERROR @%0t: host_disc set with the device attached", $time); end
        end

        errors = errors + dev.errors + host.errors;
        $display("--------------------------------------------------");
        $display("packets: %0d", pk_n);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #(500000);
        $display("TEST FAILED: timeout");
        $finish;
    end
