//-----------------------------------------------------------------------------
// tb_afe_hs_chain.v - HS receive chain through the AFE behavioural models
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_hs_chain usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_rx_nrzi_decoder.v \
//            usb_rx_sync_detect.v usb_rx_bit_unstuffer.v usb_rx_deserializer.v \
//            usb_rx_eop_check.v usb_rx_decoder.v usb_rx_elastic_buffer.v \
//            usb_rx_hs_frontend.v usb_rx_fsls_frontend.v usb_rx_datapath.v \
//            afe_line_bm.v afe_term_bm.v afe_hs_tx_bm.v afe_hs_rx_bm.v \
//            afe_squelch_bm.v afe_cdr_bm.v tb_afe_hs_chain.v
//   vvp sim_afe_hs_chain
//
// Purpose: the open A0 point "false-SYNC check for HS_ZMIN = 4 with a CDR that
// produces bad bits before lock" (DOC/afe_interface_spec.md 4.2 / 9), and the
// packet loss caused by the CDR lock time behind hubs.
//
// Chain
//   far usb_tx_path (own 480 MHz clock, random +-1000 ppm per packet)
//     -> afe_hs_tx_bm (far) -> afe_line_bm, 45 Ohm terminations at both ends
//     -> afe_hs_rx_bm (+-15 mV noise, 20 mV hysteresis: toggles on an idle line)
//     -> afe_squelch_bm (release 4 ns) and afe_cdr_bm (default loop) with
//        +-0.15 UI random edge jitter added between receiver and CDR
//     -> two usb_rx_datapath instances on the same signals: HS_ZMIN = 6 (the
//        current default) and HS_ZMIN = 4.  hs_cdr_lock = 1 (LOCK_DLY = 0,
//        spec 4.2: the front end gates with !squelch).
//   Hubs are modelled by keeping the far driver off for the first DROP bits of
//   every packet (USB 2.0: up to 4 SYNC bits per hub, 12 bits left after 5).
//
// Per packet and DUT, classification of what the datapath delivered
//   ok      : one packet, bytes = PID + payload, rx_error = 0
//   flagged : one packet with rx_error = 1 (the Link discards it; counts as lost)
//   lost    : no packet
//   rejected: wrong bytes without rx_error, but the Link's PID check or CRC16
//             rejects them (counts as lost).  This happens: a bad bit before
//             CDR lock can end SYNC detection early; the misaligned stream then
//             shows a bit-stuff violation inside the packet, which in HS is the
//             EOP, and with 7 residual bits it ends the packet without
//             rx_error.  USB relies on PID check + CRC for exactly this.
//   UNDETECTED: wrong bytes that pass PID check and CRC16, or more than one
//             packet -> the Link would accept wrong data.
//
// Checked
//   * full SYNC (DROP = 0): every packet ok in both DUTs;
//   * no UNDETECTED packet in any case;
//   * reported (no pass / fail): ok / flagged / rejected / lost per DUT for
//     DROP = 16 and DROP = 20 (16- and 12-bit SYNC).
// Packets: DATA0 PID, 1-24 random payload bytes, CRC16 (USB: x^16+x^15+x^2+1,
// LSB first, initial FFFFh, inverted).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_afe_hs_chain;
    parameter real    HALF  = 1.0416667;
    parameter integer NPKT  = 200;

    integer errors = 0;
    integer seed   = 32'h5EED_0A1F;

    // ---------------- clocks / reset ----------------
    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;
    real far_half = HALF;
    reg  clk_far  = 1'b0;
    initial begin #0.29; forever #(far_half) clk_far = ~clk_far; end

    reg rst_n = 1'b0;
    reg [2:0] ce_cnt = 3'd0, fce_cnt = 3'd0;
    wire ce60 = (ce_cnt == 3'd7), ce60_far = (fce_cnt == 3'd7);
    always @(posedge clk_bit) ce_cnt  <= ce_cnt + 3'd1;
    always @(posedge clk_far) fce_cnt <= fce_cnt + 3'd1;

    // ---------------- far transmitter ----------------
    reg  [7:0] f_b [0:127];
    integer    f_n = 0, f_idx = 0;
    reg        f_go = 1'b0, f_valid = 1'b0, f_last = 1'b0;
    reg  [7:0] f_data = 8'd0;
    wire       f_ready, f_txd, f_tx_en, f_tx_se0, f_busy, f_done, f_under;
    wire [1:0] f_tx_speed;

    usb_tx_path u_far (
        .clk_bit(clk_far), .rst_n(rst_n), .ce60(ce60_far), .speed(2'b00), .bypass_en(1'b0), .eop_dis(1'b0),
        .in_valid(f_valid), .in_ready(f_ready), .in_data(f_data), .in_last(f_last),
        .txd(f_txd), .tx_en(f_tx_en), .tx_se0(f_tx_se0), .tx_speed(f_tx_speed),
        .busy(f_busy), .tx_done(f_done), .tx_underrun(f_under));

    always @(posedge clk_far) begin
        if (rst_n && ce60_far) begin
            if (f_valid && f_ready) begin
                f_idx = f_idx + 1;
                if (f_last) f_go = 1'b0;
            end
            if (f_go && f_idx < f_n) begin
                f_valid <= 1'b1; f_data <= f_b[f_idx]; f_last <= (f_idx == f_n - 1);
            end else
                f_valid <= 1'b0;
        end
        if (f_under) begin errors = errors + 1; $display("ERROR @%0t: far underrun (testbench)", $time); end
    end

    // hub model: far driver off for the first DROP bits of a packet
    integer drop = 0, on_bits = 0;
    reg     f_drive = 1'b0;
    always @(posedge clk_far) begin
        if (!f_tx_en) on_bits = 0; else on_bits = on_bits + 1;
        f_drive <= f_tx_en && (on_bits >= drop);
    end

    // ---------------- analog chain ----------------
    wire [63:0] nt_dpg, nt_dpi, nt_dmg, nt_dmi, ft_dpg, ft_dpi, ft_dmg, ft_dmi;
    wire [63:0] fh_dpg, fh_dpi, fh_dmg, fh_dmi, dp_v, dm_v;
    wire        f_settled;
    wire [31:0] f_skew;

    afe_term_bm u_nt (.dp_pullup_en(1'b0), .dm_pullup_en(1'b0), .hs_term_en(1'b1),
                      .dp_pulldown_en(1'b0), .dm_pulldown_en(1'b0),
                      .dp_g(nt_dpg), .dp_i(nt_dpi), .dm_g(nt_dmg), .dm_i(nt_dmi));
    afe_term_bm u_ft (.dp_pullup_en(1'b0), .dm_pullup_en(1'b0), .hs_term_en(1'b1),
                      .dp_pulldown_en(1'b1), .dm_pulldown_en(1'b1),
                      .dp_g(ft_dpg), .dp_i(ft_dpi), .dm_g(ft_dmg), .dm_i(ft_dmi));
    afe_hs_tx_bm #(.T_EN(0.0), .T_DLY(0.5)) u_fh (
        .TX_IN_P(f_txd), .TX_IN_N(!f_txd), .TX_EN(f_drive),
        .dp_g(fh_dpg), .dp_i(fh_dpi), .dm_g(fh_dmg), .dm_i(fh_dmi),
        .settled(f_settled), .skew_err(f_skew));
    afe_line_bm u_line (
        .dp_g0(nt_dpg), .dp_i0(nt_dpi), .dp_g1(ft_dpg), .dp_i1(ft_dpi), .dp_g2(fh_dpg), .dp_i2(fh_dpi),
        .dp_g3(64'd0), .dp_i3(64'd0), .dp_g4(64'd0), .dp_i4(64'd0), .dp_g5(64'd0), .dp_i5(64'd0),
        .dm_g0(nt_dmg), .dm_i0(nt_dmi), .dm_g1(ft_dmg), .dm_i1(ft_dmi), .dm_g2(fh_dmg), .dm_i2(fh_dmi),
        .dm_g3(64'd0), .dm_i3(64'd0), .dm_g4(64'd0), .dm_i4(64'd0), .dm_g5(64'd0), .dm_i5(64'd0),
        .dp_v(dp_v), .dm_v(dm_v));

    wire rx_p, rx_n, squelch, disc;
    afe_hs_rx_bm   u_rx (.dp_v(dp_v), .dm_v(dm_v), .RX_EN(1'b1), .RX_OUT_P(rx_p), .RX_OUT_N(rx_n));
    afe_squelch_bm u_sq (.dp_v(dp_v), .dm_v(dm_v), .en(1'b1), .squelch(squelch), .disc(disc));

    // data-edge jitter between receiver and CDR (+-DJ, constant latency DJ)
    real dj = 0.3125;                            // 0.15 UI
    reg  cdr_in = 1'b0;
    real jj;
    always @(rx_p) begin
        jj = dj * (($random(seed) % 10000) / 10000.0);
        cdr_in <= #(dj + jj) rx_p;
    end

    wire        clk_rx, hs_rxd;
    wire [31:0] c_up, c_dn, c_bits;
    afe_cdr_bm u_cdr (.CDR_DATA(cdr_in), .CDR_EN(1'b1), .clk_rx(clk_rx), .hs_rxd(hs_rxd),
                      .n_up(c_up), .n_dn(c_dn), .n_bits(c_bits));

    // ---------------- DUTs ----------------
    wire       s6, v6, e6, r6, b6, s4, v4, e4, r4, b4;
    wire [7:0] d6, d4;
    usb_rx_datapath #(.HS_ZMIN(6)) u_dp6 (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(2'b00), .rx_en(1'b1), .tx_en(1'b0),
        .clk_rx(clk_rx), .hs_rxd(hs_rxd), .hs_squelch(squelch), .hs_cdr_lock(1'b1),
        .rxrcv(1'b1), .rxdp(1'b0), .rxdm(1'b0),
        .rx_start(s6), .rx_valid(v6), .rx_data(d6), .rx_end(e6), .rx_error(r6), .rx_busy(b6));
    usb_rx_datapath #(.HS_ZMIN(4)) u_dp4 (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(2'b00), .rx_en(1'b1), .tx_en(1'b0),
        .clk_rx(clk_rx), .hs_rxd(hs_rxd), .hs_squelch(squelch), .hs_cdr_lock(1'b1),
        .rxrcv(1'b1), .rxdp(1'b0), .rxdm(1'b0),
        .rx_start(s4), .rx_valid(v4), .rx_data(d4), .rx_end(e4), .rx_error(r4), .rx_busy(b4));

    // ---------------- receive records ----------------
    // per DUT: number of starts, bytes of the first packet, error flag, byte mismatch
    integer n_st [0:1], n_by [0:1], n_mm [0:1];
    reg     got_err [0:1];
    reg [7:0] first_b [0:1];
    reg [7:0] rb0 [0:127];
    reg [7:0] rb1 [0:127];
    integer exp_n;                                // expected bytes: PID + payload
    reg [7:0] exp_b [0:127];

    task rec(input integer i, input s, input v, input [7:0] d, input e, input r);
        begin
            if (s) n_st[i] = n_st[i] + 1;
            if (v && (n_st[i] == 1)) begin
                if (n_by[i] == 0) first_b[i] = d;
                if (n_by[i] < 128) begin if (i == 0) rb0[n_by[i]] = d; else rb1[n_by[i]] = d; end
                if ((n_by[i] >= exp_n) || (d !== exp_b[n_by[i]])) n_mm[i] = n_mm[i] + 1;
                n_by[i] = n_by[i] + 1;
            end
            if (e && r && (n_st[i] == 1)) got_err[i] = 1'b1;
        end
    endtask

    always @(posedge clk_bit) if (rst_n && ce60) begin     // one event per ce60 tick
        rec(0, s6, v6, d6, e6, r6);
        rec(1, s4, v4, d4, e4, r4);
    end

    // ---------------- per-case statistics ----------------
    integer c_ok [0:1], c_fl [0:1], c_lo [0:1], c_rj [0:1], c_ud [0:1];

    // USB CRC16 over bytes, LSB first; returns the value as transmitted (inverted)
    reg [15:0] crc;
    task crc16_byte(input [7:0] b);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1)
                crc = (b[k] ^ crc[0]) ? ((crc >> 1) ^ 16'hA001) : (crc >> 1);
        end
    endtask

    // Link acceptance of a received DATA packet: PID check + CRC16 -> lk_ok
    reg lk_ok;
    task link_check(input integer i);
        integer k, n;
        reg [7:0] pid;
        begin
            n     = n_by[i];
            pid   = i ? rb1[0] : rb0[0];
            lk_ok = 1'b0;
            if ((n >= 3) && (n <= 128) && (pid[3:0] == ~pid[7:4])) begin
                crc = 16'hFFFF;
                for (k = 1; k < n - 2; k = k + 1) crc16_byte(i ? rb1[k] : rb0[k]);
                crc = ~crc;
                lk_ok = ((i ? rb1[n-2] : rb0[n-2]) == crc[7:0]) && ((i ? rb1[n-1] : rb0[n-1]) == crc[15:8]);
            end
        end
    endtask

    task classify(input integer i);
        begin
            link_check(i);
            if (n_st[i] == 0)                                   c_lo[i] = c_lo[i] + 1;
            else if (n_st[i] > 1)                               c_ud[i] = c_ud[i] + 1;
            else if (got_err[i])                                c_fl[i] = c_fl[i] + 1;
            else if ((n_mm[i] == 0) && (n_by[i] == exp_n))      c_ok[i] = c_ok[i] + 1;
            else if (!lk_ok)                               c_rj[i] = c_rj[i] + 1;
            else                                                c_ud[i] = c_ud[i] + 1;
            if ((n_st[i] == 1) && !got_err[i] && ((n_mm[i] != 0) || (n_by[i] != exp_n)))
                $display("  wrong bytes @%0t (HS_ZMIN %0d): %0d of %0d bytes, first byte %h (sent PID %h) -> %0s",
                         $time, i ? 4 : 6, n_by[i], exp_n, first_b[i], exp_b[0],
                         lk_ok ? "UNDETECTED" : "rejected by PID check / CRC16");
            if (n_st[i] > 1)
                $display("  UNDETECTED @%0t (HS_ZMIN %0d): %0d packet starts", $time, i ? 4 : 6, n_st[i]);
        end
    endtask

    task send_one;
        integer k, npay;
        real    ppm;
        begin
            ppm = ({$random(seed)} % 2001) - 1000.0;
            far_half = HALF / (1.0 + ppm * 1.0e-6);
            npay = 1 + {$random(seed)} % 24;
            f_b[0] = 8'h00; f_b[1] = 8'h00; f_b[2] = 8'h00; f_b[3] = 8'h80;   // HS SYNC
            f_b[4] = 8'hC3;                                                   // DATA0
            crc = 16'hFFFF;
            for (k = 0; k < npay; k = k + 1) begin f_b[5 + k] = $random(seed); crc16_byte(f_b[5 + k]); end
            crc = ~crc;
            f_b[5 + npay] = crc[7:0]; f_b[6 + npay] = crc[15:8];
            f_n = 7 + npay;
            exp_n = f_n - 4;
            for (k = 0; k < exp_n; k = k + 1) exp_b[k] = f_b[4 + k];
            for (k = 0; k < 2; k = k + 1) begin n_st[k] = 0; n_by[k] = 0; n_mm[k] = 0; got_err[k] = 1'b0; end
            @(posedge clk_far);
            f_idx = 0; f_go = 1'b1;
            @(posedge clk_far);
            while (f_go || f_busy || f_tx_en) @(posedge clk_far);
            #(600.0 + ({$random(seed)} % 400000) / 1000.0);                 // gap, random phase
            classify(0); classify(1);
        end
    endtask

    task run_case(input integer d);
        integer p, i;
        begin
            drop = d;
            for (i = 0; i < 2; i = i + 1) begin c_ok[i] = 0; c_fl[i] = 0; c_lo[i] = 0; c_rj[i] = 0; c_ud[i] = 0; end
            for (p = 0; p < NPKT; p = p + 1) send_one;
            for (i = 0; i < 2; i = i + 1)
                $display("  SYNC %2d bits, HS_ZMIN %0d: ok %3d, flagged %2d, rejected %2d, lost %2d, UNDETECTED %0d  -> %0.1f %% of packets not received",
                         32 - d, i ? 4 : 6, c_ok[i], c_fl[i], c_rj[i], c_lo[i], c_ud[i],
                         100.0 * (NPKT - c_ok[i]) / NPKT);
            if ((c_ud[0] != 0) || (c_ud[1] != 0)) begin
                errors = errors + 1; $display("ERROR: wrong packet the Link would accept");
            end
        end
    endtask

    initial begin
        $dumpfile("tb_afe_hs_chain.vcd");
        $dumpvars(0, tb_afe_hs_chain);
        repeat (20) @(posedge clk_bit);
        rst_n = 1'b1;
        #2000;

        $display("[1] Full 32-bit SYNC");
        run_case(0);
        if ((c_ok[0] != NPKT) || (c_ok[1] != NPKT)) begin
            errors = errors + 1; $display("ERROR: packets not received with a full SYNC");
        end
        $display("[2] 16-bit SYNC (4 hubs)");
        run_case(16);
        $display("[3] 12-bit SYNC (5 hubs)");
        run_case(20);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #(NPKT * 3 * 5000.0 + 100000.0);           // about 1.8 us per packet; 5 us margin
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
