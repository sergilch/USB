//-----------------------------------------------------------------------------
// tb_usb_rx_fsls_frontend.v - self-checking testbench for usb_rx_fsls_frontend
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxfsfe usb_rx_fsls_frontend.v tb_usb_rx_fsls_frontend.v
//   vvp sim_rxfsfe
//
// The testbench drives D+ / D- / rxrcv with symbol frames at the FS or LS bit
// rate of a far clock with a ppm offset: idle J, then a frame that starts with
// K, random J/K runs of 1..7 bits (bit stuffing limits runs to 7), optional SE0
// pairs, and the EOP SE0 SE0 J, then idle again.  D- lags D+ by a random skew
// (SE0 / SE1 glitches at the crossovers), rxrcv switches half-way.  LS uses
// the inverted polarity (J = D- high).  Checked:
//   * the strobed symbols (b_en with b_lvl / b_se0) reproduce every frame bit
//     for bit: the first K after idle starts the comparison, each frame symbol
//     is sampled exactly once and in order, idle bits are J;
//   * about one strobe per bit time on an idle line;
//   * b_act follows enable.
//   FS at 0 / +2500 / -2500 ppm, LS at 0 / +15000 / -15000 ppm.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_fsls_frontend;

    parameter real    HALF   = 1.0416667;
    parameter integer FS_DIV = 40;
    parameter integer LS_DIV = 320;

    reg clk = 1'b0;
    always #(HALF) clk = ~clk;
    reg rst_n;

    reg  ls = 1'b0, enable = 1'b1;
    reg  dp = 1'b1, dm = 1'b0, rcv = 1'b1;    // after skew
    wire b_en, b_lvl, b_se0, b_act;

    usb_rx_fsls_frontend #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) dut (
        .clk (clk), .rst_n (rst_n),
        .rxrcv (rcv), .rxdp (dp), .rxdm (dm), .ls (ls), .enable (enable),
        .b_en (b_en), .b_lvl (b_lvl), .b_se0 (b_se0), .b_act (b_act)
    );

    integer errors = 0;
    integer seed   = 32'h0F5F_15AA;

    // ---------------- line driver ----------------
    real    bit_ns = 83.333;
    real    skew   = 0.0;
    reg [1:0] sym = 2'd1;                     // 0 K, 1 J, 2 SE0 (as driven, before skew)

    // J: FS D+ high, LS D- high
    wire dp_raw = (sym == 2'd2) ? 1'b0 : ((sym == 2'd1) ^ ls);
    wire dm_raw = (sym == 2'd2) ? 1'b0 : !((sym == 2'd1) ^ ls);
    always @(dp_raw) dp  <= #(0.3) dp_raw;
    always @(dm_raw) dm  <= #(0.3 + skew) dm_raw;
    always @(dp_raw) rcv <= #(0.3 + skew / 2.0) dp_raw;

    // ---------------- expected frames ----------------
    reg [1:0] f_sym [0:65535];
    integer   f_w = 0;                        // symbols queued (all frames)
    integer   f_start [0:4095];
    integer   f_len   [0:4095];
    integer   nf = 0, cf = 0;                 // frames queued / being checked

    // ---------------- strobe checker ----------------
    integer ck_i = -1;                        // index in the current frame, -1 = waiting for K
    integer strobes = 0, sym_ok = 0;

    always @(posedge clk) begin
        if (rst_n && b_en) begin
            strobes = strobes + 1;
            if (b_act !== enable) begin
                errors = errors + 1;
                $display("ERROR @%0t: b_act = %b, enable = %b", $time, b_act, enable);
            end
            if (ck_i < 0) begin
                if (b_se0 || !b_lvl) begin                     // first non-J: frame start
                    if (cf >= nf) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: unexpected non-J symbol on an idle line", $time);
                    end else ck_i = 0;
                end
            end
            if (ck_i >= 0) begin
                if (( b_se0 && f_sym[f_start[cf] + ck_i] != 2'd2) ||
                    (!b_se0 && f_sym[f_start[cf] + ck_i] != {1'b0, b_lvl})) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: frame %0d symbol %0d: got %s, expected %0d",
                             $time, cf, ck_i, b_se0 ? "SE0" : (b_lvl ? "J" : "K"), f_sym[f_start[cf] + ck_i]);
                    ck_i = f_len[cf] - 1;                      // skip the rest of the frame
                end else sym_ok = sym_ok + 1;
                ck_i = ck_i + 1;
                if (ck_i == f_len[cf]) begin
                    ck_i = -1;
                    cf   = cf + 1;
                end
            end
        end
    end

    // drive one symbol for one bit time
    task drive(input [1:0] s);
        begin
            sym = s;
            #(bit_ns);
        end
    endtask

    task frame(input integer nsym);
        integer i, run, k;
        reg [1:0] s;
        begin
            f_start[nf] = f_w;
            s = 2'd0;                                          // starts with K
            i = 0;
            while (i < nsym) begin
                run = 1 + {$random(seed)} % 7;
                if ({$random(seed)} % 12 == 0) begin
                    s = 2'd2; run = 1 + {$random(seed)} % 2;   // SE0 inside (reset-like)
                end
                for (k = 0; k < run && i < nsym; k = k + 1) begin
                    f_sym[f_w] = s; f_w = f_w + 1; i = i + 1;
                end
                s = (s == 2'd0) ? 2'd1 : 2'd0;
            end
            f_sym[f_w] = 2'd2; f_w = f_w + 1;                  // EOP
            f_sym[f_w] = 2'd2; f_w = f_w + 1;
            f_sym[f_w] = 2'd1; f_w = f_w + 1;
            f_len[nf] = f_w - f_start[nf];
            nf = nf + 1;
            for (i = f_start[nf - 1]; i < f_w; i = i + 1) drive(f_sym[i]);
        end
    endtask

    task idle(input integer n);
        begin
            sym = 2'd1;
            #(n * bit_ns);
        end
    endtask

    task run(input l, input real ppm, input integer frames);
        integer p, s0;
        real    tb0;
        begin
            ls     = l;
            bit_ns = (l ? LS_DIV : FS_DIV) * 2.0 * HALF / (1.0 + ppm * 1.0e-6);
            idle(20);
            // strobe rate on an idle line
            s0 = strobes; tb0 = $realtime;
            idle(100);
            if ((strobes - s0) < 98 || (strobes - s0) > 102) begin
                errors = errors + 1;
                $display("ERROR: %0d strobes in 100 idle bit times", strobes - s0);
            end
            for (p = 0; p < frames; p = p + 1) begin
                skew = ({$random(seed)} % 100) * (l ? 0.4 : 0.06);   // up to 40 ns LS, 6 ns FS
                frame(4 + {$random(seed)} % 60);
                idle(3 + {$random(seed)} % 6);
            end
            idle(10);
        end
    endtask

    initial begin
        $dumpfile("tb_usb_rx_fsls_frontend.vcd");
        $dumpvars(0, tb_usb_rx_fsls_frontend);
        rst_n = 1'b0;
        #20 rst_n = 1'b1;

        $display("FS 0 / +2500 / -2500 ppm");
        run(1'b0, 0.0, 60);
        run(1'b0, 2500.0, 40);
        run(1'b0, -2500.0, 40);
        $display("LS 0 / +15000 / -15000 ppm");
        run(1'b1, 0.0, 12);
        run(1'b1, 15000.0, 12);
        run(1'b1, -15000.0, 12);

        $display("enable -> b_act");
        ls = 1'b0; bit_ns = FS_DIV * 2.0 * HALF;
        enable = 1'b0;
        idle(5);
        enable = 1'b1;
        idle(5);

        if (cf != nf) begin
            errors = errors + 1;
            $display("ERROR: %0d of %0d frames checked", cf, nf);
        end
        $display("%0d frames, %0d symbols checked", cf, sym_ok);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
