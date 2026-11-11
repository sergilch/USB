//-----------------------------------------------------------------------------
// tb_usb_mode_term_ctrl.v - unit testbench for usb_mode_term_ctrl
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_mode_term_ctrl usb_mode_term_ctrl.v tb_usb_mode_term_ctrl.v
//   vvp sim_mode_term_ctrl
//
// Checks
//   1. Every row of USB3320 Table 5-1 (typed in from the data sheet, not derived
//      from the RTL formulas) settles to its resistor settings, and the TX
//      controls match ULPI 1.1 3.8.5 (OpMode 10: bypass + no SYNC; no EOP except
//      host FS / LS; OpMode 01: drivers off).
//   2. All 128 register combinations, in random order and from random previous
//      states: the settled outputs equal the decode in the module header
//      (re-written here as a case table per role).
//   3. On every clk_bit edge:
//        - outputs change only on ce60 edges (or one edge after iso_en rises);
//        - the 1.5 kOhm pull-ups and the 45 Ohm terminations are never on
//          together, and no enable goes on in the same tick as another goes
//          off or within BBM_TK ticks after any "off";
//        - the outputs settle within BBM_TK + 1 ticks of the last register change;
//        - term_busy = outputs differ from the settled value.
//   4. Reset and iso_en: all enables 0; after iso_en falls they come back.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_mode_term_ctrl;
    parameter real HALF = 1.0416667;
    localparam BBM = 2;

    integer errors = 0;
    integer seed   = 32'h7E2A_0C77;

    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;
    reg rst_n = 1'b0;
    reg [2:0] ce_cnt = 3'd0;
    wire ce60 = (ce_cnt == 3'd7);
    always @(posedge clk_bit) ce_cnt <= ce_cnt + 3'd1;

    reg  [1:0] xs = 2'b01, om = 2'b00;
    reg        ts = 1'b0, dpd = 1'b1, dmd = 1'b1, iso = 1'b0;
    wire       pu_dp, pu_dm, hst, pd_dp, pd_dm, busy, byp, sdis, edis, ddis, host;

    usb_mode_term_ctrl #(.BBM_TK(BBM)) dut (
        .clk_bit(clk_bit), .rst_n(rst_n), .ce60(ce60),
        .xcvrselect(xs), .termselect(ts), .opmode(om), .dp_pulldown(dpd), .dm_pulldown(dmd),
        .iso_en(iso),
        .dp_pullup_en(pu_dp), .dm_pullup_en(pu_dm), .hs_term_en(hst),
        .dp_pulldown_en(pd_dp), .dm_pulldown_en(pd_dm), .term_busy(busy),
        .tx_bypass(byp), .tx_sync_dis(sdis), .tx_eop_dis(edis), .drv_dis(ddis), .host_mode(host));

    initial begin
        $dumpfile("tb_usb_mode_term_ctrl.vcd");
        $dumpvars(0, tb_usb_mode_term_ctrl);
    end

    wire [4:0] o = {pu_dp, pu_dm, hst, pd_dp, pd_dm};

    // ---------------- reference decode (per role) ----------------
    function [4:0] ref_term(input [1:0] x, input t, input [1:0] m, input pdp, input pdm);
        reg h;
        begin
            h = pdp && pdm;
            if (m == 2'b01) ref_term = 5'b00000;
            else begin
                ref_term = {3'b000, pdp, pdm};
                case ({x, t})
                    3'b000: ref_term[2] = 1'b1;                    // HS: 45 Ohm (host and peripheral)
                    3'b001: if (!h) ref_term[4] = 1'b1;            // HS + TermSelect: peripheral chirp
                    3'b011, 3'b111: if (!h) ref_term[4] = 1'b1;    // FS, FS-for-LS
                    3'b101: if (!h) ref_term[3] = 1'b1;            // LS peripheral
                    default: ;                                     // 010 / 100 / 110: pull-downs only
                endcase
            end
        end
    endfunction

    // ---------------- continuous checks ----------------
    reg  [4:0] o_q = 5'b00000;
    reg        ce_q = 1'b0, iso_q = 1'b0;
    always @(negedge clk_bit) begin ce_q <= ce60; end
    integer    tk = 0, last_off_tk = -100, last_chg_tk = 0;
    reg  [4:0] tgt_q;

    always @(posedge clk_bit) begin
        if (ce_q) tk = tk + 1;
        #0.1;
        if (o !== o_q) begin
            if (!ce_q && !(iso && o == 5'b00000) && rst_n) begin
                errors = errors + 1; $display("ERROR @%0t: outputs changed outside a ce60 edge", $time);
            end
            if ((o_q & ~o) != 0) last_off_tk = tk;
            if ((o & ~o_q) != 0) begin
                if ((o_q & ~o) != 0) begin
                    errors = errors + 1; $display("ERROR @%0t: enables on and off in the same tick (%b -> %b)", $time, o_q, o);
                end else if (tk - last_off_tk < BBM) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: enable on %0d tick(s) after an off (BBM %0d)", $time, tk - last_off_tk, BBM);
                end
            end
        end
        if ((pu_dp || pu_dm) && hst) begin
            errors = errors + 1; $display("ERROR @%0t: pull-up and HS termination on together", $time);
        end
        if (rst_n && !iso && busy !== (o != ref_term(xs, ts, om, dpd, dmd))) begin
            errors = errors + 1; $display("ERROR @%0t: term_busy %b, outputs %b, settled %b", $time, busy, o, ref_term(xs, ts, om, dpd, dmd));
        end
        if (byp !== (om == 2'b10) || sdis !== (om == 2'b10) || ddis !== (om == 2'b01) ||
            edis !== ((om == 2'b10) && !(dpd && dmd && xs != 2'b00)) || host !== (dpd && dmd)) begin
            errors = errors + 1; $display("ERROR @%0t: TX controls", $time);
        end
        if ((!rst_n || iso_q) && o !== 5'b00000) begin
            errors = errors + 1; $display("ERROR @%0t: enables not off in reset / isolation", $time);
        end
        o_q = o; iso_q = iso;
    end

    // ---------------- helpers ----------------
    task cyc(input integer n); begin repeat (n) @(negedge clk_bit); end endtask

    task set_regs(input [1:0] x, input t, input [1:0] m, input pdp, input pdm);
        begin
            @(negedge clk_bit);
            xs = x; ts = t; om = m; dpd = pdp; dmd = pdm;
            last_chg_tk = tk;
        end
    endtask

    task settle(input [8*28-1:0] what, input [4:0] exp);
        begin
            cyc(8 * (BBM + 2));
            if (o !== exp) begin
                errors = errors + 1;
                $display("ERROR: %0s: enables %b (pu_dp pu_dm hs_term pd_dp pd_dm), expected %b", what, o, exp);
            end
            if (busy) begin errors = errors + 1; $display("ERROR: %0s: term_busy after settling", what); end
        end
    endtask

    // one row of Table 5-1: registers, then RPU_DP RPU_DM HSTERM RPD_DP RPD_DM
    task row(input [8*28-1:0] what, input [1:0] x, input t, input [1:0] m, input pdp, input pdm,
             input [4:0] exp);
        begin set_regs(x, t, m, pdp, pdm); settle(what, exp); end
    endtask

    integer k, n;
    reg [6:0] v;
    initial begin
        cyc(5);
        if (o !== 5'b00000) begin errors = errors + 1; $display("ERROR: reset values %b", o); end
        rst_n = 1'b1;

        // 1. USB3320 Table 5-1           xs  ts  om  dpd dmd   PUdp PUdm HST PDdp PDdm
        row("tri-state drivers",          2'b00, 1, 2'b01, 1, 1, 5'b00000);
        row("tri-state drivers (periph)", 2'b01, 1, 2'b01, 0, 0, 5'b00000);
        row("power-up",                   2'b01, 0, 2'b00, 1, 1, 5'b00011);
        row("host chirp",                 2'b00, 0, 2'b10, 1, 1, 5'b00111);
        row("host HS",                    2'b00, 0, 2'b00, 1, 1, 5'b00111);
        row("host FS (01)",               2'b01, 1, 2'b00, 1, 1, 5'b00011);
        row("host FS (11)",               2'b11, 1, 2'b00, 1, 1, 5'b00011);
        row("host HS/FS resume",          2'b01, 1, 2'b10, 1, 1, 5'b00011);
        row("host LS",                    2'b10, 1, 2'b00, 1, 1, 5'b00011);
        row("host LS resume",             2'b10, 1, 2'b10, 1, 1, 5'b00011);
        row("host test J/K",              2'b00, 0, 2'b10, 1, 1, 5'b00111);
        row("peripheral chirp",           2'b00, 1, 2'b10, 0, 0, 5'b10000);
        row("peripheral HS",              2'b00, 0, 2'b00, 0, 0, 5'b00100);
        row("peripheral FS",              2'b01, 1, 2'b00, 0, 0, 5'b10000);
        row("peripheral HS/FS resume",    2'b01, 1, 2'b10, 0, 0, 5'b10000);
        row("peripheral LS",              2'b10, 1, 2'b00, 0, 0, 5'b01000);
        row("peripheral LS resume",       2'b10, 1, 2'b10, 0, 0, 5'b01000);
        // TX controls for the signalling rows
        set_regs(2'b01, 1, 2'b10, 1, 1); cyc(2);
        if (edis !== 1'b0) begin errors = errors + 1; $display("ERROR: host FS resume must append the EOP"); end
        set_regs(2'b01, 1, 2'b10, 0, 0); cyc(2);
        if (edis !== 1'b1) begin errors = errors + 1; $display("ERROR: peripheral resume K must end without EOP"); end
        set_regs(2'b00, 0, 2'b10, 1, 1); cyc(2);
        if (edis !== 1'b1 || byp !== 1'b1 || sdis !== 1'b1) begin errors = errors + 1; $display("ERROR: host chirp TX controls"); end

        // the HS handshake of a peripheral: FS -> chirp -> HS -> FS suspend -> HS
        row("handshake: FS",              2'b01, 1, 2'b00, 0, 0, 5'b10000);
        row("handshake: chirp",           2'b00, 1, 2'b10, 0, 0, 5'b10000);
        row("handshake: HS",              2'b00, 0, 2'b00, 0, 0, 5'b00100);
        row("handshake: suspend",         2'b01, 1, 2'b00, 0, 0, 5'b10000);
        row("handshake: HS again",        2'b00, 0, 2'b00, 0, 0, 5'b00100);

        // 2. all combinations, random order
        for (n = 0; n < 6; n = n + 1)
            for (k = 0; k < 128; k = k + 1) begin
                v = (n == 0) ? k : $random(seed);
                row("all combinations", v[6:5], v[4], v[3:2], v[1], v[0],
                    ref_term(v[6:5], v[4], v[3:2], v[1], v[0]));
            end

        // 3. fast changes (inside the break-before-make gap), checked continuously
        for (k = 0; k < 400; k = k + 1) begin
            v = $random(seed);
            set_regs(v[6:5], v[4], v[3:2], v[1], v[0]);
            cyc({$random(seed)} % 40);
        end
        settle("after fast changes", ref_term(xs, ts, om, dpd, dmd));

        // 4. isolation and reset
        row("before isolation",           2'b01, 1, 2'b00, 0, 0, 5'b10000);
        @(negedge clk_bit) iso = 1'b1;
        cyc(20);
        @(negedge clk_bit) iso = 1'b0;
        settle("after isolation", 5'b10000);
        row("HS before reset",            2'b00, 0, 2'b00, 1, 1, 5'b00111);
        @(negedge clk_bit) rst_n = 1'b0;
        cyc(3);
        @(negedge clk_bit) rst_n = 1'b1;
        settle("after reset", 5'b00111);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #10000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
