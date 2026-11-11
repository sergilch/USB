//-----------------------------------------------------------------------------
// tb_ams_pwr_shadow.v - Icarus counterpart of the Spectre AMS power-up / PLL
//                       test AFE/ams/tb_ams_pwr.vams
//
// Run (Icarus Verilog):
//   iverilog -g2005 -I AFE/ams -o sim_ams_pwr_shadow usb_pwr_seq.v \
//            usb_pll_lock_det.v usb_clk_gen.v afe_pll_bm.v tb_ams_pwr_shadow.v
//   vvp sim_ams_pwr_shadow
//
// Same DUT chain (usb_pwr_seq, usb_pll_lock_det, usb_clk_gen) and the same
// stimulus / checks (AFE/ams/ams_pwr_seq.vh) as the AMS testbench.  Here the
// PLL is afe_pll_bm and the two LDOs are delays with the afe_ldo.va default
// timing (VDD33 ramp 100 us, UVLO 2.7 V, soft start 50 us, PWR_GOOD 10 us
// after 1.62 V, POR_N 100 us after PWR_GOOD): POR_N 212 us after the ramp
// starts, PG18A 61 us after LDO_EN.  REF_DIG is the 24 MHz reference while
// VDD18A is up.  About 450 us simulated.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_ams_pwr_shadow;
    localparam real VIN_RAMP = 100000.0;
    localparam real T_XO     = 1000.0 / 24.0;

    reg vin_on = 1'b0, pwr_good = 1'b0, susp_req = 1'b0, clk_susp = 1'b0, wake = 1'b0;

    // ---------------- LDO stand-ins ----------------
    reg por_n = 1'b0, pg18a = 1'b0, vdd18a_up = 1'b0;
    always @(posedge vin_on) begin #(212000.0); por_n = 1'b1; end
    wire ldo_en;
    always @(ldo_en) begin
        if (ldo_en === 1'b1) begin
            #(51000.0); if (ldo_en === 1'b1) vdd18a_up = 1'b1;
            #(10000.0); if (ldo_en === 1'b1) pg18a = 1'b1;
        end else begin vdd18a_up = 1'b0; pg18a = 1'b0; end
    end

    // ---------------- reference, PLL ----------------
    reg xo = 1'b0;
    always #(T_XO / 2.0) xo = ~xo;
    wire ref_clk = xo & vdd18a_up;
    wire clk_bit, pll_lock, lol, refsel_err, ce60, clk60, clk_on;
    wire [4:0] fb_div;
    wire bias_en, pll_en, iso_en, core_rst_n_b, iso_en_b, afe_en_b, dir_hold_b, clk_en_b, pll_err;
    wire [3:0] state;

    afe_pll_bm u_pll (.CDR_FREF(ref_clk), .PLL_EN(pll_en & vdd18a_up), .clk_out(clk_bit));
    always @(fb_div) if (fb_div != 5'd0) u_pll.DIV = fb_div;
    usb_pll_lock_det u_ld (.clk_bit(clk_bit), .ref_clk(ref_clk), .rst_n(por_n), .pll_en(pll_en),
                           .refsel(2'b01), .lol_clr(1'b0), .pll_lock(pll_lock), .lol(lol),
                           .fb_div(fb_div), .refsel_err(refsel_err));
    usb_clk_gen u_cg (.clk_bit(clk_bit), .rst_n(por_n), .clk_en(clk_en_b),
                      .ce60(ce60), .clk60(clk60), .clk_on(clk_on));
    usb_pwr_seq u_seq (
        .ref_clk(ref_clk), .clk_bit(clk_bit), .por_n(por_n),
        .pwr_good(pwr_good), .pg18a(pg18a), .pll_lock(pll_lock), .clk_on(clk_on),
        .susp_req(susp_req), .clk_susp(clk_susp), .wake(wake),
        .bias_en(bias_en), .ldo_en(ldo_en), .pll_en(pll_en), .iso_en(iso_en),
        .core_rst_n_b(core_rst_n_b), .iso_en_b(iso_en_b), .afe_en_b(afe_en_b),
        .dir_hold_b(dir_hold_b), .clk_en_b(clk_en_b), .state(state), .pll_err(pll_err));

    initial begin
        $dumpfile("tb_ams_pwr_shadow.vcd");
        $dumpvars(0, tb_ams_pwr_shadow);
    end

    `define AMS_V18A (vdd18a_up ? 1.8 : 0.0)
    `include "ams_pwr_seq.vh"
endmodule
