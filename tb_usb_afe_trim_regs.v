//-----------------------------------------------------------------------------
// tb_usb_afe_trim_regs.v - unit testbench for usb_afe_trim_regs (phase A7)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_trim_regs usb_afe_trim_regs.v tb_usb_afe_trim_regs.v
//   vvp sim_afe_trim_regs
//
// Checks
//   [1] reset values of every register (map typed in from the module header) and
//       of every trim output; reserved addresses read 00h
//   [2] writable bits per register (write FFh / 00h), reserved bits read 0
//   [3] shadow / active: shadow writes do not move any output; UPDATE moves all
//       of them in one tick; RDACT selects the set that is read; bit 7 of 3Eh
//   [4] TEST (3Ch) acts at once; PWR_STAT shows the synchronized status, only
//       values that were on the input (the two-sample filter against a bit-wise
//       mix needs metastability, so RTL simulation cannot show it);
//       writing bit 6 of 3Dh pulses lol_clr for one tick
//   [5] random lockstep run against a reference model (writes, UPDATE, RDACT,
//       reads in the read tick), ce one tick in 8
//   Continuous: outputs change only on ce edges.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_afe_trim_regs;
    integer errors = 0;
    integer seed   = 32'h0A7_7713;

    reg clk = 1'b0;
    always #1.0416667 clk = ~clk;
    reg rst_n = 1'b0;
    reg [2:0] cc = 3'd0;
    wire ce = (cc == 3'd7);
    always @(posedge clk) cc <= cc + 3'd1;

    reg        wr = 1'b0;
    reg  [3:0] addr = 4'd0;
    reg  [7:0] wdata = 8'd0;
    wire [7:0] rdata;
    reg  [3:0] pst = 4'd0;
    reg        perr = 1'b0, plock = 1'b0, plol = 1'b0;
    wire       lol_clr;
    wire [3:0] tx_amp, atb;
    wire [2:0] hs_term, tx_lag, rx_vth, rx_hyst, sq_vth, disc_vth, cdr_icp, pll_icp, lock_dly, sq_comp;
    wire [4:0] tx_lead;
    wire [1:0] cdr_band;
    wire       lpbk;

    usb_afe_trim_regs dut (
        .clk_bit(clk), .rst_n(rst_n), .ce(ce),
        .vnd_wr(wr), .vnd_addr(addr), .vnd_wdata(wdata), .vnd_rdata(rdata),
        .pwr_state(pst), .pll_err(perr), .pll_lock(plock), .lol(plol), .lol_clr(lol_clr),
        .trim_tx_amp(tx_amp), .trim_hs_term(hs_term), .trim_tx_lead(tx_lead), .trim_tx_lag(tx_lag),
        .trim_rx_vth(rx_vth), .trim_rx_hyst(rx_hyst), .trim_sq_vth(sq_vth), .trim_disc_vth(disc_vth),
        .trim_cdr_icp(cdr_icp), .trim_cdr_band(cdr_band), .trim_pll_icp(pll_icp),
        .trim_lock_dly(lock_dly), .trim_sq_comp(sq_comp), .atb_sel(atb), .ana_lpbk(lpbk));

    initial begin
        $dumpfile("tb_usb_afe_trim_regs.vcd");
        $dumpvars(0, tb_usb_afe_trim_regs);
    end

    // outputs packed back into register images (30h-36h), from the header map
    wire [55:0] out_img = {2'b00, sq_comp, lock_dly,  5'b00000, pll_icp,  3'b000, cdr_band, cdr_icp,
                           2'b00, disc_vth, sq_vth,   2'b00, rx_hyst, rx_vth,  tx_lag, tx_lead,
                           1'b0, hs_term, tx_amp};
    localparam [55:0] DEF  = {8'h02, 8'h04, 8'h0C, 8'h24, 8'h24, 8'h0A, 8'h48};
    localparam [55:0] MSK  = {8'h3F, 8'h07, 8'h1F, 8'h3F, 8'h3F, 8'hFF, 8'h7F};

    // ---------------- continuous: change only on ce edges ----------------
    reg [60:0] o_q; reg ce_q = 1'b0;
    wire [60:0] o_all = {lol_clr, lpbk, atb, out_img};
    always @(posedge clk) begin
        ce_q = ce;
        #0.1;
        if (rst_n && o_all !== o_q && !ce_q) begin
            errors = errors + 1; $display("ERROR @%0t: outputs changed outside a ce edge", $time);
        end
        o_q = o_all;
    end

    // ---------------- access helpers ----------------
    task tick; begin @(negedge clk); while (!ce) @(negedge clk); end endtask   // just before a ce edge
    task wreg(input [3:0] a, input [7:0] d);
        begin tick; wr = 1'b1; addr = a; wdata = d; @(posedge clk); #0.1; @(negedge clk); wr = 1'b0; end
    endtask
    task rchk(input [3:0] a, input [7:0] exp, input [8*24-1:0] what);
        begin
            tick; addr = a; #0.1;
            if (rdata !== exp) begin
                errors = errors + 1; $display("ERROR @%0t: %0s: read %h = %02h, expected %02h", $time, what, a, rdata, exp);
            end
        end
    endtask
    function [7:0] byte_of(input [55:0] v, input integer k); byte_of = v[k*8 +: 8]; endfunction

    // ---------------- reference model for [5] ----------------
    reg [55:0] m_shd, m_act; reg m_rdact; reg [4:0] m_test;
    function [7:0] m_read(input [3:0] a);
        begin
            m_read = 8'h00;
            if (a <= 4'h6)      m_read = byte_of(m_rdact ? m_act : m_shd, a);
            else if (a == 4'hC) m_read = {3'b000, m_test};
            else if (a == 4'hD) m_read = {1'b0, plol, perr, plock, pst};   // held static in [5]
            else if (a == 4'hE) m_read = {(m_shd != m_act), 5'b00000, m_rdact, 1'b0};
        end
    endfunction

    integer k, n, a;
    reg [55:0] img;
    reg [7:0]  r;
    reg [6:0]  seen [0:15];
    integer    nseen;
    reg [6:0]  sv;
    reg        ok;
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        // [1] reset values
        for (k = 0; k < 7; k = k + 1) rchk(k, byte_of(DEF, k), "reset shadow");
        for (k = 7; k < 16; k = k + 1) if (k != 4'hD) rchk(k, 8'h00, "reset / reserved");
        if (out_img !== DEF || atb !== 4'd0 || lpbk !== 1'b0 || lol_clr !== 1'b0) begin
            errors = errors + 1; $display("ERROR: outputs after reset %h", out_img);
        end
        if (tx_lead !== 5'd10 || lock_dly !== 3'd2 || sq_comp !== 3'd0 || tx_lag !== 3'd0) begin
            errors = errors + 1; $display("ERROR: digital trim defaults (lead %0d lock_dly %0d)", tx_lead, lock_dly);
        end
        wreg(4'hE, 8'h02);
        for (k = 0; k < 7; k = k + 1) rchk(k, byte_of(DEF, k), "reset active");
        wreg(4'hE, 8'h00);

        // [2] writable bits
        for (k = 0; k < 7; k = k + 1) begin
            wreg(k, 8'hFF); rchk(k, byte_of(MSK, k), "write FFh");
            wreg(k, 8'h00); rchk(k, 8'h00, "write 00h");
        end
        for (k = 7; k < 16; k = k + 1) if (k != 4'hD && k != 4'hE && k != 4'hC) begin
            wreg(k, 8'hFF); rchk(k, 8'h00, "reserved");
        end
        rchk(4'hE, 8'h80, "differs flag");
        if (out_img !== DEF) begin errors = errors + 1; $display("ERROR: shadow writes moved the outputs"); end

        // [3] shadow / active
        img = 56'h15_03_17_2D_1B_E5_6C & MSK;
        for (k = 0; k < 7; k = k + 1) wreg(k, byte_of(img, k));
        if (out_img !== DEF) begin errors = errors + 1; $display("ERROR: shadow writes moved the outputs"); end
        tick; wr = 1'b1; addr = 4'hE; wdata = 8'h01;
        @(posedge clk); #0.2;
        if (out_img !== img) begin
            errors = errors + 1; $display("ERROR: UPDATE: outputs %h, expected %h (all in one tick)", out_img, img);
        end
        @(negedge clk); wr = 1'b0;
        rchk(4'hE, 8'h00, "after UPDATE");
        for (k = 0; k < 7; k = k + 1) wreg(k, 8'h00);
        wreg(4'hE, 8'h02);
        for (k = 0; k < 7; k = k + 1) rchk(k, byte_of(img, k), "RDACT");
        rchk(4'hE, 8'h82, "RDACT + differs");
        if (out_img !== img) begin errors = errors + 1; $display("ERROR: outputs moved without UPDATE"); end
        wreg(4'hE, 8'h03);
        if (out_img !== 56'd0) begin errors = errors + 1; $display("ERROR: UPDATE to zero"); end
        rchk(4'hE, 8'h02, "RDACT, equal");

        // [4] TEST, PWR_STAT, lol_clr
        wreg(4'hC, 8'hFF);
        if (atb !== 4'hF || lpbk !== 1'b1) begin errors = errors + 1; $display("ERROR: TEST not immediate"); end
        rchk(4'hC, 8'h1F, "TEST");
        wreg(4'hC, 8'h00);
        // status: random steps, some held long, some glitches of 1-3 clk_bit cycles
        nseen = 0;
        for (n = 0; n < 300; n = n + 1) begin
            @(negedge clk);
            sv = $random(seed);
            {plol, perr, plock, pst} = sv;
            if (({$random(seed)} % 4) == 0) begin
                repeat (100) @(negedge clk);
                rchk(4'hD, {1'b0, sv}, "PWR_STAT settled");
            end else
                repeat ({$random(seed)} % 4) @(negedge clk);
        end
        // lol_clr
        tick; wr = 1'b1; addr = 4'hD; wdata = 8'h40;
        @(posedge clk); #0.2;
        if (lol_clr !== 1'b1) begin errors = errors + 1; $display("ERROR: lol_clr not set"); end
        @(negedge clk); wr = 1'b0;
        repeat (8) @(posedge clk); #0.2;
        if (lol_clr !== 1'b0) begin errors = errors + 1; $display("ERROR: lol_clr longer than one tick"); end

        // [5] random lockstep
        wreg(4'hE, 8'h00);
        for (k = 0; k < 7; k = k + 1) wreg(k, byte_of(DEF, k));
        wreg(4'hE, 8'h01);
        m_shd = DEF; m_act = DEF; m_rdact = 1'b0; m_test = 5'd0;
        for (n = 0; n < 4000; n = n + 1) begin
            tick;
            r = $random(seed);
            a = {$random(seed)} % 16;
            if (({$random(seed)} % 8) == 0) a = 4'hE;
            wr = r[0]; addr = a; wdata = $random(seed);
            #0.1;
            if (rdata !== m_read(a)) begin
                errors = errors + 1; $display("ERROR @%0t: lockstep read %h = %02h, model %02h", $time, a, rdata, m_read(a));
            end
            if (wr) begin
                if (a <= 6) m_shd[a*8 +: 8] = wdata & MSK[a*8 +: 8];
                if (a == 12) m_test = wdata[4:0];
                if (a == 14) begin m_rdact = wdata[1]; if (wdata[0]) m_act = m_shd; end
            end
            @(posedge clk); #0.2;
            if (out_img !== m_act || atb !== m_test[3:0] || lpbk !== m_test[4]) begin
                errors = errors + 1; $display("ERROR @%0t: lockstep outputs %h, model %h", $time, out_img, m_act);
            end
            @(negedge clk); wr = 1'b0;
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    // PWR_STAT coherence monitor: the register may only take a value that was on
    // the inputs at some time (a real input value, never a bit-wise mix)
    reg [6:0] in_now, in_prev; integer hold = 0;
    reg [6:0] stable_set [0:127];
    integer i;
    initial for (i = 0; i < 128; i = i + 1) stable_set[i] = 7'd0;
    always @(posedge clk) begin
        in_now = {plol, perr, plock, pst};
        if (in_now === in_prev) hold = hold + 1; else hold = 0;
        stable_set[in_now] = 7'd1;
        in_prev = in_now;
    end
    reg [6:0] st_q = 7'd0;
    always @(posedge clk) begin
        #0.3;
        if (rst_n && dut.stat !== st_q) begin
            if (stable_set[dut.stat] !== 7'd1 && dut.stat !== 7'd0) begin
                errors = errors + 1; $display("ERROR @%0t: PWR_STAT took %02h, never stable at the input", $time, dut.stat);
            end
            st_q = dut.stat;
        end
    end

    initial begin
        #2000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
