//-----------------------------------------------------------------------------
// tb_ams_link_shadow.v - Icarus counterpart of the Spectre AMS line test
//                        AFE/ams/tb_ams_link.vams
//
// Run (Icarus Verilog):
//   iverilog -g2005 -I AFE/ams -o sim_ams_link_shadow \
//            usb_bit_stuffer.v usb_nrzi_encoder.v usb_tx_serializer.v usb_tx_path.v \
//            usb_afe_tx_if.v usb_afe_rx_if.v usb_rx_nrzi_decoder.v usb_rx_sync_detect.v \
//            usb_rx_bit_unstuffer.v usb_rx_deserializer.v usb_rx_eop_check.v \
//            usb_rx_decoder.v usb_rx_elastic_buffer.v usb_rx_hs_frontend.v \
//            usb_rx_fsls_frontend.v usb_rx_datapath.v usb_rx_status_flt.v \
//            usb_rx_status_sync.v usb_line_state.v usb_mode_term_ctrl.v \
//            afe_line_bm.v afe_term_bm.v afe_hs_tx_bm.v afe_fsls_bm.v afe_hs_rx_bm.v \
//            afe_squelch_bm.v afe_cdr_bm.v AFE/ams/ams_phy_end.v tb_ams_link_shadow.v
//   vvp sim_ams_link_shadow
//
// Same two ends (AFE/ams/ams_phy_end.v), same Link models, sequence and checks
// (AFE/ams/ams_link_seq.vh) as the AMS testbench; only the AFE differs: here
// each end's pins drive afe_term_bm, afe_hs_tx_bm, afe_fsls_bm, afe_hs_rx_bm,
// afe_squelch_bm and afe_cdr_bm on one afe_line_bm, instead of the Verilog-A
// models through connect modules.  So every regression run checks the digital
// half of the AMS testbench and its sequence; a failure in Spectre AMS that
// does not show here points at the analog models, the connect rules or the
// AMS netlist.  Device clk_bit nominal, host +400 ppm.  About 60 us simulated.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ams_link_shadow;
    parameter real HALF  = 1.0416667;
    parameter real PPM_H = 400.0;

    reg clk_d = 1'b0, clk_h = 1'b0;
    always #(HALF) clk_d = ~clk_d;
    always #(HALF / (1.0 + PPM_H * 1.0e-6)) clk_h = ~clk_h;
    reg rst_n = 1'b0;

    wire [63:0] dp_v, dm_v;
    wire [63:0] d_g [0:5], d_i [0:5];      // device: t / h / f, dp then dm
    wire [63:0] h_g [0:5], h_i [0:5];

    // ---------------- device ----------------
    wire d_pu, d_pum, d_hst, d_pdp, d_pdm, d_hp, d_hn, d_hen, d_foe, d_fdat, d_fse0, d_fls;
    wire d_rxen, d_cdren, d_clkrx, d_rxd, d_sq, d_disc, d_rdp, d_rdm, d_rcv;
    ams_phy_end #(.HOST(0), .SEED(21)) dev (
        .clk(clk_d), .rst_n(rst_n),
        .dp_pullup_en(d_pu), .dm_pullup_en(d_pum), .hs_term_en(d_hst),
        .dp_pulldown_en(d_pdp), .dm_pulldown_en(d_pdm),
        .hs_tx_p(d_hp), .hs_tx_n(d_hn), .hs_tx_en(d_hen),
        .fs_oe(d_foe), .fs_dat(d_fdat), .fs_se0(d_fse0), .fs_ls(d_fls),
        .rx_en_hs(d_rxen), .cdr_en(d_cdren),
        .clk_rx(d_clkrx), .hs_rxd_a(d_rxd), .squelch_a(d_sq), .disc_a(d_disc),
        .rxdp_a(d_rdp), .rxdm_a(d_rdm), .rxrcv_a(d_rcv));
    ams_shadow_afe #(.SEED(21)) d_afe (
        .dp_pullup_en(d_pu), .dm_pullup_en(d_pum), .hs_term_en(d_hst),
        .dp_pulldown_en(d_pdp), .dm_pulldown_en(d_pdm),
        .hs_tx_p(d_hp), .hs_tx_n(d_hn), .hs_tx_en(d_hen),
        .fs_oe(d_foe), .fs_dat(d_fdat), .fs_se0(d_fse0), .fs_ls(d_fls),
        .rx_en_hs(d_rxen), .cdr_en(d_cdren),
        .clk_rx(d_clkrx), .hs_rxd_a(d_rxd), .squelch_a(d_sq), .disc_a(d_disc),
        .rxdp_a(d_rdp), .rxdm_a(d_rdm), .rxrcv_a(d_rcv),
        .dp_v(dp_v), .dm_v(dm_v),
        .t_dpg(d_g[0]), .t_dpi(d_i[0]), .t_dmg(d_g[3]), .t_dmi(d_i[3]),
        .h_dpg(d_g[1]), .h_dpi(d_i[1]), .h_dmg(d_g[4]), .h_dmi(d_i[4]),
        .f_dpg(d_g[2]), .f_dpi(d_i[2]), .f_dmg(d_g[5]), .f_dmi(d_i[5]));

    // ---------------- host ----------------
    wire h_pu, h_pum, h_hst, h_pdp, h_pdm, h_hp, h_hn, h_hen, h_foe, h_fdat, h_fse0, h_fls;
    wire h_rxen, h_cdren, h_clkrx, h_rxd, h_sq, h_disc, h_rdp, h_rdm, h_rcv;
    ams_phy_end #(.HOST(1), .SEED(37)) host (
        .clk(clk_h), .rst_n(rst_n),
        .dp_pullup_en(h_pu), .dm_pullup_en(h_pum), .hs_term_en(h_hst),
        .dp_pulldown_en(h_pdp), .dm_pulldown_en(h_pdm),
        .hs_tx_p(h_hp), .hs_tx_n(h_hn), .hs_tx_en(h_hen),
        .fs_oe(h_foe), .fs_dat(h_fdat), .fs_se0(h_fse0), .fs_ls(h_fls),
        .rx_en_hs(h_rxen), .cdr_en(h_cdren),
        .clk_rx(h_clkrx), .hs_rxd_a(h_rxd), .squelch_a(h_sq), .disc_a(h_disc),
        .rxdp_a(h_rdp), .rxdm_a(h_rdm), .rxrcv_a(h_rcv));
    ams_shadow_afe #(.SEED(37)) h_afe (
        .dp_pullup_en(h_pu), .dm_pullup_en(h_pum), .hs_term_en(h_hst),
        .dp_pulldown_en(h_pdp), .dm_pulldown_en(h_pdm),
        .hs_tx_p(h_hp), .hs_tx_n(h_hn), .hs_tx_en(h_hen),
        .fs_oe(h_foe), .fs_dat(h_fdat), .fs_se0(h_fse0), .fs_ls(h_fls),
        .rx_en_hs(h_rxen), .cdr_en(h_cdren),
        .clk_rx(h_clkrx), .hs_rxd_a(h_rxd), .squelch_a(h_sq), .disc_a(h_disc),
        .rxdp_a(h_rdp), .rxdm_a(h_rdm), .rxrcv_a(h_rcv),
        .dp_v(dp_v), .dm_v(dm_v),
        .t_dpg(h_g[0]), .t_dpi(h_i[0]), .t_dmg(h_g[3]), .t_dmi(h_i[3]),
        .h_dpg(h_g[1]), .h_dpi(h_i[1]), .h_dmg(h_g[4]), .h_dmi(h_i[4]),
        .f_dpg(h_g[2]), .f_dpi(h_i[2]), .f_dmg(h_g[5]), .f_dmi(h_i[5]));

    afe_line_bm u_line (
        .dp_g0(d_g[0]), .dp_i0(d_i[0]), .dp_g1(d_g[1]), .dp_i1(d_i[1]),
        .dp_g2(d_g[2]), .dp_i2(d_i[2]), .dp_g3(h_g[0]), .dp_i3(h_i[0]),
        .dp_g4(h_g[1]), .dp_i4(h_i[1]), .dp_g5(h_g[2]), .dp_i5(h_i[2]),
        .dm_g0(d_g[3]), .dm_i0(d_i[3]), .dm_g1(d_g[4]), .dm_i1(d_i[4]),
        .dm_g2(d_g[5]), .dm_i2(d_i[5]), .dm_g3(h_g[3]), .dm_i3(h_i[3]),
        .dm_g4(h_g[4]), .dm_i4(h_i[4]), .dm_g5(h_g[5]), .dm_i5(h_i[5]),
        .dp_v(dp_v), .dm_v(dm_v));

    initial begin
        $dumpfile("tb_ams_link_shadow.vcd");
        $dumpvars(0, tb_ams_link_shadow);
    end

    `define AMS_VDP $bitstoreal(dp_v)
    `define AMS_VDM $bitstoreal(dm_v)
    `include "ams_link_seq.vh"
endmodule

//-----------------------------------------------------------------------------
// ams_shadow_afe: the event-driven AFE of one end (the afe_*_bm.v models), in
// place of afe_transceiver + afe_receiver + afe_cdr of the AMS testbench
//-----------------------------------------------------------------------------
module ams_shadow_afe #(parameter SEED = 1) (
    input  wire dp_pullup_en, dm_pullup_en, hs_term_en, dp_pulldown_en, dm_pulldown_en,
    input  wire hs_tx_p, hs_tx_n, hs_tx_en, fs_oe, fs_dat, fs_se0, fs_ls,
    input  wire rx_en_hs, cdr_en,
    output wire clk_rx, hs_rxd_a, squelch_a, disc_a, rxdp_a, rxdm_a, rxrcv_a,
    input  wire [63:0] dp_v, dm_v,
    output wire [63:0] t_dpg, t_dpi, t_dmg, t_dmi,
    output wire [63:0] h_dpg, h_dpi, h_dmg, h_dmi,
    output wire [63:0] f_dpg, f_dpi, f_dmg, f_dmi
);
    wire hx_settled, rx_p, rx_n;
    wire [31:0] skew_err, c_up, c_dn, c_bits;
    afe_term_bm u_term (.dp_pullup_en(dp_pullup_en), .dm_pullup_en(dm_pullup_en), .hs_term_en(hs_term_en),
                        .dp_pulldown_en(dp_pulldown_en), .dm_pulldown_en(dm_pulldown_en),
                        .dp_g(t_dpg), .dp_i(t_dpi), .dm_g(t_dmg), .dm_i(t_dmi));
    afe_hs_tx_bm u_hstx (.TX_IN_P(hs_tx_p), .TX_IN_N(hs_tx_n), .TX_EN(hs_tx_en),
                         .dp_g(h_dpg), .dp_i(h_dpi), .dm_g(h_dmg), .dm_i(h_dmi),
                         .settled(hx_settled), .skew_err(skew_err));
    afe_fsls_bm u_fsls (.fs_oe(fs_oe), .fs_dat(fs_dat), .fs_se0(fs_se0), .fs_ls(fs_ls),
                        .dp_g(f_dpg), .dp_i(f_dpi), .dm_g(f_dmg), .dm_i(f_dmi),
                        .rx_en(1'b1), .dp_v(dp_v), .dm_v(dm_v),
                        .rxdp(rxdp_a), .rxdm(rxdm_a), .rxrcv(rxrcv_a));
    afe_hs_rx_bm   #(.SEED(SEED)) u_hsrx (.dp_v(dp_v), .dm_v(dm_v), .RX_EN(rx_en_hs), .RX_OUT_P(rx_p), .RX_OUT_N(rx_n));
    afe_squelch_bm u_sq (.dp_v(dp_v), .dm_v(dm_v), .en(rx_en_hs), .squelch(squelch_a), .disc(disc_a));
    afe_cdr_bm     #(.SEED(SEED + 1)) u_cdr (.CDR_DATA(rx_p), .CDR_EN(cdr_en), .clk_rx(clk_rx), .hs_rxd(hs_rxd_a),
                                             .n_up(c_up), .n_dn(c_dn), .n_bits(c_bits));
endmodule
