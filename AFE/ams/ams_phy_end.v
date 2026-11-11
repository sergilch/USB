//-----------------------------------------------------------------------------
// ams_phy_end.v - one end of the USB line (device or host): the digital PHY
//                 below ULPI plus a Link model's hooks, with the AFE pins as
//                 plain digital ports
//
// Used by both
//   * AFE/ams/tb_ams_link.vams  (Spectre AMS: the ports go through connect
//     modules into the Verilog-A models afe_transceiver / afe_receiver /
//     afe_cdr), and
//   * tb_ams_link_shadow.v      (Icarus: the same ports drive the event-driven
//     models afe_*_bm.v), which checks this module and the shared sequence
//     AFE/ams/ams_link_seq.vh on every regression run.
// Plain Verilog-2005, no AMS constructs, so it compiles in both.
//
//   registers xs / ts / om / dpd / dmd (set_regs) -> usb_mode_term_ctrl
//     -> dp_pullup_en, dm_pullup_en, hs_term_en, dp/dm_pulldown_en
//   byte feeder (load_pkt / load_pattern / go / wait_tx) -> usb_tx_path
//     (bypass / eop_dis from usb_mode_term_ctrl) -> usb_afe_tx_if
//     -> hs_tx_p/n, hs_tx_en, fs_oe/dat/se0/ls
//   clk_rx, hs_rxd_a, squelch_a -> usb_afe_rx_if (lock_dly 2) -> usb_rx_datapath
//     (HS_ZMIN 4); rx_en_hs, cdr_en back to the AFE
//   rxdp_a, rxdm_a, rxrcv_a, squelch_a, disc_a -> usb_rx_status_sync
//     -> usb_line_state (ls, hd) and the FS / LS input of usb_rx_datapath
//   receive monitor: rm_pk, rm_n, rm_b[], rm_err, rm_start_n; own errors count
//
// Packets: load_pkt(npay) = SYNC (4 bytes 00 00 00 80 at HS, 1 byte 80 at FS /
//   LS) + a random PID + npay random bytes (one in four FFh, for bit stuffing);
//   exp_b[0 .. exp_n-1] is what the far end must receive.
// load_pattern(n, per): OpMode 10 signalling, n bytes of 00h (per = 0, a K)
//   or alternating runs of per bytes 00h / FFh (chirp K-J pairs).
//
// Clock: clk = this end's clk_bit; ce60 generated here (1 in 8).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module ams_phy_end #(
    parameter HOST = 0,
    parameter SEED = 1
) (
    input  wire clk,
    input  wire rst_n,

    // terminations
    output wire dp_pullup_en,
    output wire dm_pullup_en,
    output wire hs_term_en,
    output wire dp_pulldown_en,
    output wire dm_pulldown_en,
    // HS transmitter
    output wire hs_tx_p,
    output wire hs_tx_n,
    output wire hs_tx_en,
    // FS / LS transmitter
    output wire fs_oe,
    output wire fs_dat,
    output wire fs_se0,
    output wire fs_ls,
    // HS receiver / CDR control
    output wire rx_en_hs,
    output wire cdr_en,
    // from the AFE
    input  wire clk_rx,
    input  wire hs_rxd_a,
    input  wire squelch_a,
    input  wire disc_a,
    input  wire rxdp_a,
    input  wire rxdm_a,
    input  wire rxrcv_a
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

    wire t_busy, byp, sdis, edis, ddis, hmode;
    usb_mode_term_ctrl u_mode (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60),
        .xcvrselect(xs), .termselect(ts), .opmode(om), .dp_pulldown(dpd), .dm_pulldown(dmd),
        .iso_en(1'b0),
        .dp_pullup_en(dp_pullup_en), .dm_pullup_en(dm_pullup_en), .hs_term_en(hs_term_en),
        .dp_pulldown_en(dp_pulldown_en), .dm_pulldown_en(dm_pulldown_en), .term_busy(t_busy),
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
    reg  [7:0] pids [0:7];
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

    task load_pkt(input integer npay);
        integer i, ns;
        begin
            f_idx = 1 << 30; f_pat = 1'b0;
            exp_n = npay + 1;
            exp_b[0] = pids[{$random(seed)} % 8];
            for (i = 1; i <= npay; i = i + 1) exp_b[i] = ({$random(seed)} % 4 == 0) ? 8'hFF : $random(seed);
            ns = (xs == 2'b00) ? 4 : 1;
            for (i = 0; i < ns - 1; i = i + 1) fb[i] = 8'h00;
            fb[ns - 1] = 8'h80;
            for (i = 0; i <= npay; i = i + 1) fb[ns + i] = exp_b[i];
            f_n = npay + 1 + ns;
        end
    endtask

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
    wire txd, tx_en, tx_se0, tx_busy, tx_done, tx_under, tx_act;
    wire [1:0] tx_spd;
    usb_tx_path u_tx (
        .clk_bit(clk), .rst_n(rst_n), .ce60(ce60), .speed(xs), .bypass_en(byp), .eop_dis(edis),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data), .in_last(in_last),
        .txd(txd), .tx_en(tx_en), .tx_se0(tx_se0), .tx_speed(tx_spd),
        .busy(tx_busy), .tx_done(tx_done), .tx_underrun(tx_under));
    usb_afe_tx_if u_afe_tx (
        .clk_bit(clk), .rst_n(rst_n),
        .txd(txd), .tx_en(tx_en), .tx_se0(tx_se0), .tx_speed(tx_spd),
        .tx_lead(5'd10), .tx_lag(3'd0), .drv_dis(ddis), .iso_en(1'b0), .lead_first(byp),
        .hs_tx_p(hs_tx_p), .hs_tx_n(hs_tx_n), .hs_tx_en(hs_tx_en),
        .fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls), .tx_active(tx_act));
    always @(posedge clk) if (tx_under) begin
        errors = errors + 1; $display("ERROR @%0t: %0s TX underrun", $time, HOST ? "host" : "device");
    end

    // ---------------- receive side ----------------
    wire hs_rxd, hs_sq, hs_lock;
    usb_afe_rx_if u_afe_rx (
        .clk_bit(clk), .rst_n(rst_n), .speed(xs), .rx_en(1'b1), .iso_en(1'b0),
        .lock_dly(3'd2), .sq_comp(3'd0), .rx_en_hs(rx_en_hs), .cdr_en(cdr_en),
        .clk_rx(clk_rx), .hs_rxd_a(hs_rxd_a), .squelch_a(squelch_a),
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
