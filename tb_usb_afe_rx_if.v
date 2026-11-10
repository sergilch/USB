//-----------------------------------------------------------------------------
// tb_usb_afe_rx_if.v - HS receive boundary through the AFE models (phase A3)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_rx_if usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_rx_nrzi_decoder.v \
//            usb_rx_sync_detect.v usb_rx_bit_unstuffer.v usb_rx_deserializer.v \
//            usb_rx_eop_check.v usb_rx_decoder.v usb_rx_elastic_buffer.v \
//            usb_rx_hs_frontend.v usb_rx_fsls_frontend.v usb_rx_datapath.v \
//            usb_afe_rx_if.v afe_line_bm.v afe_term_bm.v afe_hs_tx_bm.v \
//            afe_hs_rx_bm.v afe_squelch_bm.v afe_cdr_bm.v tb_usb_afe_rx_if.v
//   vvp sim_afe_rx_if                 (statistics: add -PTB.NPKT=300 or more)
//
// Chain (AFE_INTEGRATION_PLAN.md phase A3)
//   far usb_tx_path (own clock, random +-1000 ppm per packet), hub model
//   (far driver off for the first DROP bits: SYNC on the line = 32 - DROP)
//     -> afe_hs_tx_bm -> afe_line_bm, 45 Ohm at both ends
//     -> afe_hs_rx_bm (+-15 mV noise: toggles on an idle line), afe_squelch_bm
//     -> CDR: either an ideal CDR (clock = far clock, sampled in the middle of
//        the bit; wrong bits only where the testbench injects them) or
//        afe_cdr_bm with +-0.15 UI data jitter
//     -> lock-time injection: the first L bits of the packet on the line are
//        delivered as random bits (a CDR that needs L bits to lock)
//     -> 6 DUTs in parallel, usb_afe_rx_if followed by usb_rx_datapath:
//          DUT        0     1     2     3     4     5
//          HS_ZMIN    6     4     4     4     4     6
//          lock_dly   0     0     2     4     0     0
//          sq_comp    0     0     0     0     2     2
//        DUT 0 is the current RTL default, DUT 2 the recommended setting.
//
// Checks
//   * DUT pins, every clk_rx / clk_bit edge, against a reference model:
//     hs_rxd = input delayed by 3 + sq_comp, hs_squelch / hs_cdr_lock from the
//     squelch synchronizer and lock_dly, isolation values, rx_en_hs / cdr_en
//     per speed / rx_en / iso_en.
//   * Packets per DUT, classified as in tb_afe_hs_chain: ok, flagged
//     (rx_error), lost, rejected (wrong bytes caught by PID check / CRC16),
//     UNDETECTED (wrong data the Link would accept, or two packet starts).
//     UNDETECTED is always an error.
//   [2] Digital lock-time margin (ideal CDR, 12-bit SYNC, squelch 4 / 12 ns):
//       the largest L with no lost packet, per DUT.  Required: >= LMARG_REQ (6)
//       for the recommended setting.
//   [3] Squelch release T_ON 4-16 ns (12-bit SYNC, ideal CDR): no loss for the
//       recommended setting up to 12 ns.
//   [4] Squelch hold T_OFF 6-12 ns (32-bit SYNC, packets up to 64 bytes): no
//       loss for the recommended setting (the EOP must still get through).
//   [6] Model chain (afe_cdr_bm, 0.15 UI jitter) with 32-, 16- and 12-bit SYNC:
//       no loss with a 32-bit SYNC for sq_comp = 0; the rest is reported (run with NPKT = 300
//       or more for statistics).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_afe_rx_if;
    parameter real    HALF      = 1.0416667;
    parameter integer NPKT      = 30;            // packets per sweep point
    parameter integer LMARG_REQ = 6;             // required digital lock-time margin (bits)
    localparam        NI        = 6;             // DUT instances
    localparam integer REC      = 2;             // recommended instance (see table below)

    // DUT configurations:   0     1     2     3     4     5
    //   HS_ZMIN             6     4     4     4     4     6
    //   sq_comp             0     0     0     0     2     2
    //   lock_dly            0     0     2     4     0     0
    function integer zm(input integer i); zm = (i == 0 || i == 5) ? 6 : 4;          endfunction
    function integer kc(input integer i); kc = (i >= 4) ? 2 : 0;                    endfunction
    function integer dl(input integer i); dl = (i == 2) ? 2 : (i == 3) ? 4 : 0;     endfunction

    integer errors = 0;
    integer seed   = 32'h0A3C_0DE5;

    // ---------------- clocks / reset ----------------
    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;
    real far_half = HALF;
    reg  clk_far  = 1'b0;
    initial begin #0.37; forever #(far_half) clk_far = ~clk_far; end

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
        .clk_bit(clk_far), .rst_n(rst_n), .ce60(ce60_far), .speed(2'b00), .bypass_en(1'b0),
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

    // enables come from DUT 0 (all DUTs get the same mode inputs)
    wire [NI-1:0] rx_en_hs_w, cdr_en_w;
    wire rx_en_hs = rx_en_hs_w[0], cdr_en = cdr_en_w[0];

    wire rx_p, rx_n, squelch, disc;
    afe_hs_rx_bm   u_rx (.dp_v(dp_v), .dm_v(dm_v), .RX_EN(rx_en_hs), .RX_OUT_P(rx_p), .RX_OUT_N(rx_n));
    afe_squelch_bm u_sq (.dp_v(dp_v), .dm_v(dm_v), .en(rx_en_hs), .squelch(squelch), .disc(disc));

    // model CDR with data-edge jitter (+-dj)
    real dj = 0.3125;                            // 0.15 UI
    reg  cdr_in = 1'b0;
    real jj;
    always @(rx_p) begin
        jj = dj * (($random(seed) % 10000) / 10000.0);
        cdr_in <= #(dj + jj) rx_p;
    end
    wire        clk_cdr, cdr_d;
    wire [31:0] c_up, c_dn, c_bits;
    afe_cdr_bm u_cdr (.CDR_DATA(cdr_in), .CDR_EN(cdr_en), .clk_rx(clk_cdr), .hs_rxd(cdr_d),
                      .n_up(c_up), .n_dn(c_dn), .n_bits(c_bits));

    // ideal CDR: the far clock, rising edge in the middle of the bit at the
    // receiver output (driver 0.5 ns + receiver 0.3 ns + half a bit)
    reg  clk_id = 1'b0, id_d = 1'b1;
    always @(clk_far) clk_id <= #(0.8 + HALF) clk_far;
    always @(posedge clk_id) id_d <= #(0.3) rx_p;

    // clock select (switched only while both clocks are low)
    reg  use_id = 1'b1;
    wire clk_rx = use_id ? clk_id : clk_cdr;
    task sel_cdr(input ideal);
        begin
            while (clk_id || clk_cdr) #0.05;
            use_id = ideal;
        end
    endtask

    // lock-time injection: the first inj_L bits on the line come out random
    integer inj_L = 0, inj_cnt = 0;
    real    t_drv = 1.0e12;
    reg     inj_q = 1'b0, rnd_q = 1'b0;
    always @(posedge f_drive) begin t_drv = $realtime; inj_cnt = 0; end
    always @(posedge clk_rx) begin
        if (($realtime > t_drv + 0.8) && (inj_cnt < inj_L)) begin
            inj_cnt = inj_cnt + 1;
            inj_q <= #(0.3) 1'b1;
        end else
            inj_q <= #(0.3) 1'b0;
        rnd_q <= #(0.3) $random(seed);
    end
    wire hs_rxd_a = inj_q ? rnd_q : (use_id ? id_d : cdr_d);

    // ---------------- DUTs ----------------
    reg  [1:0] speed = 2'b00;
    reg        rx_en = 1'b1, iso_en = 1'b0;

    wire [NI-1:0] o_rxd, o_sq, o_lk;
    wire [NI-1:0] r_st, r_vl, r_en, r_er, r_bz;
    wire [8*NI-1:0] r_dt;

    genvar g;
    generate
        for (g = 0; g < NI; g = g + 1) begin : dut
            localparam [2:0]  KC = (g >= 4) ? 2 : 0;
            localparam [2:0]  DL = (g == 2) ? 2 : (g == 3) ? 4 : 0;
            localparam integer ZM = (g == 0 || g == 5) ? 6 : 4;
            usb_afe_rx_if u_if (
                .clk_bit(clk_bit), .rst_n(rst_n), .speed(speed), .rx_en(rx_en), .iso_en(iso_en),
                .lock_dly(DL), .sq_comp(KC),
                .rx_en_hs(rx_en_hs_w[g]), .cdr_en(cdr_en_w[g]),
                .clk_rx(clk_rx), .hs_rxd_a(hs_rxd_a), .squelch_a(squelch),
                .hs_rxd(o_rxd[g]), .hs_squelch(o_sq[g]), .hs_cdr_lock(o_lk[g]));
            usb_rx_datapath #(.HS_ZMIN(ZM)) u_dp (
                .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60), .speed(speed), .rx_en(rx_en), .tx_en(1'b0),
                .clk_rx(clk_rx), .hs_rxd(o_rxd[g]), .hs_squelch(o_sq[g]), .hs_cdr_lock(o_lk[g]),
                .rxrcv(1'b1), .rxdp(1'b0), .rxdm(1'b0),
                .rx_start(r_st[g]), .rx_valid(r_vl[g]), .rx_data(r_dt[8*g +: 8]),
                .rx_end(r_en[g]), .rx_error(r_er[g]), .rx_busy(r_bz[g]));
        end
    endgenerate

    // =====================================================================
    // Pin reference model
    // =====================================================================
    integer pin_err = 0;
    task perr(input [8*16-1:0] what, input integer i, input got, input exp);
        begin
            if (got !== exp) begin
                pin_err = pin_err + 1;
                if (pin_err <= 20) $display("ERROR @%0t: DUT %0d %0s = %b, expected %b", $time, i, what, got, exp);
            end
        end
    endtask

    // clk_bit side: enables
    reg e_en = 1'b0;
    always @(posedge clk_bit) begin
        if (rst_n) for (k = 0; k < NI; k = k + 1) begin
            perr("rx_en_hs", k, rx_en_hs_w[k], e_en);
            perr("cdr_en", k, cdr_en_w[k], e_en);
        end
        e_en = rst_n && rx_en && !iso_en && (speed == 2'b00);
    end

    // clk_rx side: data delay, squelch / lock (after the DUT's clk_rx reset release)
    reg     dh [0:15];
    reg     m_sq1 = 1'b1, m_sq2 = 1'b1, m_sqo = 1'b1, m_in;
    reg     m_lk [0:NI-1];
    initial for (k = 0; k < NI; k = k + 1) m_lk[k] = 1'b0;
    integer m_cnt = 0, rxe = 0, hp = 0, k;
    always @(posedge clk_rx) begin
        if (!rst_n) rxe = 0;
        else begin
            if (rxe >= 24) for (k = 0; k < NI; k = k + 1) begin
                perr("hs_rxd", k, o_rxd[k], dh[(hp - 3 - kc(k)) & 15]);
                perr("hs_squelch", k, o_sq[k], m_sqo);
                perr("hs_cdr_lock", k, o_lk[k], m_lk[k]);
            end
            // model update (pre-edge values, like the DUT)
            m_sqo = m_sq2;
            for (k = 0; k < NI; k = k + 1) m_lk[k] = !m_sq2 && (m_cnt >= dl(k));
            if (m_sq2) m_cnt = 0; else if (m_cnt < 7) m_cnt = m_cnt + 1;
            m_sq2 = m_sq1;
            m_sq1 = squelch | iso_en;
            dh[hp & 15] = hs_rxd_a | iso_en;
            hp = hp + 1;
            if (rxe < 24) rxe = rxe + 1;
        end
    end

    // =====================================================================
    // Receive records and classification (as tb_afe_hs_chain)
    // =====================================================================
    integer n_st [0:NI-1], n_by [0:NI-1], n_mm [0:NI-1];
    reg     got_err [0:NI-1];
    reg [7:0] rb [0:NI*128-1];
    integer exp_n;
    reg [7:0] exp_b [0:127];
    integer c_ok [0:NI-1], c_fl [0:NI-1], c_lo [0:NI-1], c_rj [0:NI-1], c_ud [0:NI-1];
    integer i_r;
    reg [7:0] dtmp;

    always @(posedge clk_bit) if (rst_n && ce60) begin
        for (i_r = 0; i_r < NI; i_r = i_r + 1) begin
            dtmp = r_dt[8*i_r +: 8];
            if (r_st[i_r]) n_st[i_r] = n_st[i_r] + 1;
            if (r_vl[i_r] && (n_st[i_r] == 1)) begin
                if (n_by[i_r] < 128) rb[128*i_r + n_by[i_r]] = dtmp;
                if ((n_by[i_r] >= exp_n) || (dtmp !== exp_b[n_by[i_r]])) n_mm[i_r] = n_mm[i_r] + 1;
                n_by[i_r] = n_by[i_r] + 1;
            end
            if (r_en[i_r] && r_er[i_r] && (n_st[i_r] == 1)) got_err[i_r] = 1'b1;
        end
    end

    reg [15:0] crc;
    task crc16_byte(input [7:0] b);
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1)
                crc = (b[q] ^ crc[0]) ? ((crc >> 1) ^ 16'hA001) : (crc >> 1);
        end
    endtask

    reg lk_ok;
    task link_check(input integer i);
        integer q, n;
        reg [7:0] pid;
        begin
            n = n_by[i]; pid = rb[128*i]; lk_ok = 1'b0;
            if ((n >= 3) && (n <= 128) && (pid[3:0] == ~pid[7:4])) begin
                crc = 16'hFFFF;
                for (q = 1; q < n - 2; q = q + 1) crc16_byte(rb[128*i + q]);
                crc = ~crc;
                lk_ok = (rb[128*i + n - 2] == crc[7:0]) && (rb[128*i + n - 1] == crc[15:8]);
            end
        end
    endtask

    task classify(input integer i);
        begin
            link_check(i);
            if (n_st[i] == 0)                              c_lo[i] = c_lo[i] + 1;
            else if (n_st[i] > 1)                          c_ud[i] = c_ud[i] + 1;
            else if (got_err[i])                           c_fl[i] = c_fl[i] + 1;
            else if ((n_mm[i] == 0) && (n_by[i] == exp_n)) c_ok[i] = c_ok[i] + 1;
            else if (!lk_ok)                               c_rj[i] = c_rj[i] + 1;
            else                                           c_ud[i] = c_ud[i] + 1;
            if ((n_st[i] > 1) || ((n_st[i] == 1) && !got_err[i] && lk_ok && ((n_mm[i] != 0) || (n_by[i] != exp_n))))
                $display("  UNDETECTED @%0t (DUT %0d): %0d starts, %0d bytes", $time, i, n_st[i], n_by[i]);
        end
    endtask

    task send_one(input integer maxpay);
        integer q, npay;
        real    ppm;
        begin
            ppm = ({$random(seed)} % 2001) - 1000.0;
            far_half = HALF / (1.0 + ppm * 1.0e-6);
            npay = 1 + {$random(seed)} % maxpay;
            f_b[0] = 8'h00; f_b[1] = 8'h00; f_b[2] = 8'h00; f_b[3] = 8'h80;
            f_b[4] = ({$random(seed)} % 2) ? 8'hC3 : 8'h4B;               // DATA0 / DATA1
            crc = 16'hFFFF;
            for (q = 0; q < npay; q = q + 1) begin f_b[5 + q] = $random(seed); crc16_byte(f_b[5 + q]); end
            crc = ~crc;
            f_b[5 + npay] = crc[7:0]; f_b[6 + npay] = crc[15:8];
            f_n = 7 + npay;
            exp_n = f_n - 4;
            for (q = 0; q < exp_n; q = q + 1) exp_b[q] = f_b[4 + q];
            for (q = 0; q < NI; q = q + 1) begin n_st[q] = 0; n_by[q] = 0; n_mm[q] = 0; got_err[q] = 1'b0; end
            @(posedge clk_far);
            f_idx = 0; f_go = 1'b1;
            @(posedge clk_far);
            while (f_go || f_busy || f_tx_en) @(posedge clk_far);
            #(300.0 + ({$random(seed)} % 200000) / 1000.0);             // gap, random phase
            for (q = 0; q < NI; q = q + 1) classify(q);
        end
    endtask

    task clr_stats;
        integer q;
        begin
            for (q = 0; q < NI; q = q + 1) begin c_ok[q] = 0; c_fl[q] = 0; c_lo[q] = 0; c_rj[q] = 0; c_ud[q] = 0; end
        end
    endtask

    // run npkt packets; nl[i] = packets not received (flagged + rejected + lost + undetected)
    integer nl [0:NI-1];
    task run_pts(input integer npkt, input integer maxpay);
        integer p, q;
        begin
            clr_stats;
            for (p = 0; p < npkt; p = p + 1) send_one(maxpay);
            for (q = 0; q < NI; q = q + 1) begin
                nl[q] = npkt - c_ok[q];
                if (c_ud[q] != 0) begin
                    errors = errors + 1; $display("ERROR: DUT %0d: wrong packet the Link would accept", q);
                end
            end
        end
    endtask

    task show_row(input [8*24-1:0] lbl);
        begin
            $display("    %0s | %5d %5d %5d %5d %5d %5d", lbl, nl[0], nl[1], nl[2], nl[3], nl[4], nl[5]);
        end
    endtask
    task show_head;
        begin
            $display("    %0s   packets not received of %0d, per DUT:", "                        ", NPKT);
            $display("    %0s | Z6    Z4    Z4    Z4    Z4    Z6     (HS_ZMIN)", "                        ");
            $display("    %0s |             dly2  dly4  comp2 comp2", "                        ");
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    integer L, marg [0:NI-1], q, t;
    reg     done_m [0:NI-1];
    real    ton [0:3];
    real    toff [0:3];

    initial begin
        $dumpfile("tb_usb_afe_rx_if.vcd");
        $dumpvars(1, tb_usb_afe_rx_if);
        ton[0] = 4.0; ton[1] = 8.0; ton[2] = 12.0; ton[3] = 16.0;
        toff[0] = 6.0; toff[1] = 8.0; toff[2] = 12.0;
        repeat (20) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        #2000;

        // ---------------- [1] enables, isolation ----------------
        $display("[1] enables per speed / rx_en / iso_en, isolation values");
        @(negedge clk_bit) speed = 2'b01;  #200;
        if (rx_en_hs || cdr_en) begin errors = errors + 1; $display("ERROR: HS RX / CDR on in FS mode"); end
        @(negedge clk_bit) speed = 2'b00; rx_en = 1'b0; #200;
        if (rx_en_hs || cdr_en) begin errors = errors + 1; $display("ERROR: HS RX / CDR on with rx_en = 0"); end
        @(negedge clk_bit) rx_en = 1'b1; iso_en = 1'b1; #200;
        if (rx_en_hs || cdr_en || !(&o_sq) || !(&o_rxd) || (|o_lk)) begin
            errors = errors + 1; $display("ERROR: isolation values");
        end
        @(negedge clk_bit) iso_en = 1'b0; #500;
        if (!rx_en_hs || !cdr_en) begin errors = errors + 1; $display("ERROR: HS RX / CDR off in HS mode"); end

        // ---------------- [2] digital lock-time margin ----------------
        $display("[2] digital lock-time margin: ideal CDR, 12-bit SYNC, first L bits random, squelch 4 / 12 ns");
        sel_cdr(1'b1);
        drop = 20;
        show_head;
        for (q = 0; q < NI; q = q + 1) begin marg[q] = -1; done_m[q] = 1'b0; end
        for (L = 0; L <= 8; L = L + 1) begin
            inj_L = L;
            run_pts(NPKT, 8);
            show_row(L == 0 ? "L = 0 bits              " :
                     L == 1 ? "L = 1                   " : L == 2 ? "L = 2                   " :
                     L == 3 ? "L = 3                   " : L == 4 ? "L = 4                   " :
                     L == 5 ? "L = 5                   " : L == 6 ? "L = 6                   " :
                     L == 7 ? "L = 7                   " :          "L = 8                   ");
            for (q = 0; q < NI; q = q + 1) begin
                if (nl[q] != 0) done_m[q] = 1'b1;
                if (!done_m[q]) marg[q] = L;
            end
        end
        inj_L = 0;
        $display("    margin (largest L without loss)                %5d %5d %5d %5d %5d %5d",
                 marg[0], marg[1], marg[2], marg[3], marg[4], marg[5]);
        if (marg[REC] < LMARG_REQ) begin
            errors = errors + 1;
            $display("ERROR: lock-time margin %0d bits of the recommended setting < %0d", marg[REC], LMARG_REQ);
        end

        // ---------------- [3] squelch release time ----------------
        $display("[3] squelch release time T_ON: ideal CDR, 12-bit SYNC");
        show_head;
        for (t = 0; t < 4; t = t + 1) begin
            u_sq.T_ON = ton[t];
            run_pts(NPKT, 8);
            show_row(t == 0 ? "T_ON 4 ns               " : t == 1 ? "T_ON 8 ns               " :
                     t == 2 ? "T_ON 12 ns              " :          "T_ON 16 ns              ");
            if ((ton[t] <= 12.0) && (nl[REC] != 0)) begin
                errors = errors + 1; $display("ERROR: loss with the recommended setting at T_ON %0.1f ns", ton[t]);
            end
        end
        u_sq.T_ON = 4.0;

        // ---------------- [4] squelch hold time ----------------
        $display("[4] squelch hold time T_OFF: ideal CDR, 32-bit SYNC, up to 64-byte packets");
        drop = 0;
        show_head;
        for (t = 0; t < 3; t = t + 1) begin
            u_sq.T_OFF = toff[t];
            run_pts(NPKT, 64);
            show_row(t == 0 ? "T_OFF 6 ns              " : t == 1 ? "T_OFF 8 ns              " :
                              "T_OFF 12 ns             ");
            if (nl[REC] != 0) begin
                errors = errors + 1; $display("ERROR: loss with the recommended setting at T_OFF %0.1f ns", toff[t]);
            end
        end
        u_sq.T_OFF = 12.0;

        // ---------------- [6] model chain ----------------
        $display("[6] model chain: afe_cdr_bm, 0.15 UI jitter, +-1000 ppm");
        sel_cdr(1'b0);
        #500;
        show_head;
        drop = 0;  run_pts(NPKT, 24); show_row("SYNC 32 bits            ");
        // sq_comp > 0 with HS_ZMIN = 4 can take idle-line noise for a SYNC even
        // with a full SYNC (seen in long runs): reported, not required
        for (q = 0; q < NI; q = q + 1)
            if ((nl[q] != 0) && (kc(q) == 0)) begin
                errors = errors + 1; $display("ERROR: DUT %0d lost packets with a full SYNC", q);
            end
        drop = 16; run_pts(NPKT, 24); show_row("SYNC 16 bits            ");
        drop = 20; run_pts(NPKT, 24); show_row("SYNC 12 bits            ");

        errors = errors + pin_err;
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #(NPKT * 30 * 3000.0 + 1000000.0);
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
