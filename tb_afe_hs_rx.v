//-----------------------------------------------------------------------------
// tb_afe_hs_rx.v - unit testbench for afe_hs_rx_bm and afe_squelch_bm
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_afe_hs_rx afe_hs_rx_bm.v afe_squelch_bm.v tb_afe_hs_rx.v
//   vvp sim_afe_hs_rx
//
// The testbench drives the wire voltages directly (no line model).
//
// Checked
//   [1] HS receiver: polarity (DP > DM -> RX_OUT_P = 1), complement output,
//       delay T_DLY, hysteresis (holds inside +-V_HYS/2, switches outside),
//       offset V_OFF, RX_EN = 0 values; noise off.
//   [2] Noise on an idle line: the output toggles at random (expected
//       behaviour before squelch / lock), and never toggles on a 400 mV signal.
//   [3] Squelch: falls T_SQ_ON after the line becomes active (400 mV), not on
//       a 100 mV signal, stays low through 0 V crossings shorter than
//       T_SQ_OFF, rises T_SQ_OFF after the line goes idle; activity shorter
//       than T_SQ_ON is ignored; en = 0 values.
//   [4] Disconnect: 800 mV (no far termination) -> disc after T_DISC;
//       400 mV and 500 mV -> no disc; 650 mV -> disc.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_afe_hs_rx;
    integer errors = 0;

    reg  [63:0] dp_v = 64'd0, dm_v = 64'd0;
    reg         rx_en = 1'b1, sq_en = 1'b1;
    wire        rxp, rxn, squelch, disc;

    afe_hs_rx_bm   #(.P_NOISE(0.0)) u_rx (.dp_v(dp_v), .dm_v(dm_v), .RX_EN(rx_en),
                                          .RX_OUT_P(rxp), .RX_OUT_N(rxn));
    afe_squelch_bm u_sq (.dp_v(dp_v), .dm_v(dm_v), .en(sq_en), .squelch(squelch), .disc(disc));

    task set_vd(input real vd);              // differential voltage, centred at 0.2 V
        begin
            if (vd >= 0.0) begin dp_v = $realtobits(vd); dm_v = $realtobits(0.0); end
            else           begin dp_v = $realtobits(0.0); dm_v = $realtobits(-vd); end
        end
    endtask

    task chk(input [8*40-1:0] what, input got, input exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0s = %b, expected %b", $time, what, got, exp);
            end
        end
    endtask

    integer toggles, i;
    reg     last;
    real    t0, t_sq;

    initial begin
        $dumpfile("tb_afe_hs_rx.vcd");
        $dumpvars(0, tb_afe_hs_rx);

        $display("[1] HS receiver: polarity, delay, hysteresis, offset, enable");
        set_vd(-0.4); #5;
        chk("RX_OUT_P at -400 mV", rxp, 1'b0); chk("RX_OUT_N at -400 mV", rxn, 1'b1);
        set_vd(0.4); #0.2;
        chk("RX_OUT_P 0.2 ns after edge (T_DLY 0.3)", rxp, 1'b0);
        #0.2;
        chk("RX_OUT_P 0.4 ns after edge", rxp, 1'b1); chk("RX_OUT_N", rxn, 1'b0);
        set_vd(-0.005); #1; chk("holds at -5 mV (hysteresis +-10 mV)", rxp, 1'b1);
        set_vd(-0.015); #1; chk("switches at -15 mV", rxp, 1'b0);
        set_vd(0.005);  #1; chk("holds at +5 mV", rxp, 1'b0);
        set_vd(0.015);  #1; chk("switches at +15 mV", rxp, 1'b1);
        u_rx.V_OFF = 0.05;
        set_vd(0.03);   #1; chk("offset 50 mV: +30 mV reads as negative", rxp, 1'b0);
        u_rx.V_OFF = 0.0;
        rx_en = 1'b0; set_vd(0.4); #1;
        chk("RX_OUT_P, RX_EN = 0", rxp, 1'b0); chk("RX_OUT_N, RX_EN = 0", rxn, 1'b1);
        rx_en = 1'b1; #1;

        $display("[2] Noise");
        u_rx.V_NOISE = 0.015;
        set_vd(0.0); toggles = 0; last = rxp;
        for (i = 0; i < 400; i = i + 1) begin #1; if (rxp !== last) toggles = toggles + 1; last = rxp; end
        $display("  idle line, +-15 mV noise, +-10 mV hysteresis: %0d toggles in 400 ns", toggles);
        if (toggles < 10) begin errors = errors + 1; $display("ERROR: noise does not toggle the output"); end
        set_vd(0.4); #2; toggles = 0; last = rxp;
        for (i = 0; i < 400; i = i + 1) begin #1; if (rxp !== last) toggles = toggles + 1; last = rxp; end
        if (toggles != 0) begin errors = errors + 1; $display("ERROR: %0d toggles on a 400 mV signal", toggles); end
        u_rx.V_NOISE = 0.0;

        $display("[3] Squelch");
        set_vd(0.0); #50;
        chk("squelch on an idle line", squelch, 1'b1);
        set_vd(0.1); #50;
        chk("squelch at 100 mV", squelch, 1'b1);
        set_vd(0.4); t0 = $realtime;
        wait (squelch == 1'b0); t_sq = $realtime - t0;
        $display("  squelch release after %0.2f ns (T_SQ_ON 4.0)", t_sq);
        if ((t_sq < 3.9) || (t_sq > 4.1)) begin errors = errors + 1; $display("ERROR: squelch release time"); end
        for (i = 0; i < 20; i = i + 1) begin           // HS data with zero crossings
            #2.08; set_vd((i % 2) ? 0.4 : -0.4);
        end
        set_vd(0.0); #8; chk("squelch through an 8 ns gap", squelch, 1'b0);
        set_vd(0.4); #20;
        set_vd(0.0); t0 = $realtime;
        wait (squelch == 1'b1); t_sq = $realtime - t0;
        $display("  squelch assert after %0.2f ns idle (T_SQ_OFF 12.0)", t_sq);
        if ((t_sq < 11.9) || (t_sq > 12.1)) begin errors = errors + 1; $display("ERROR: squelch assert time"); end
        set_vd(0.4); #3; set_vd(0.0); #20;
        chk("3 ns burst ignored", squelch, 1'b1);
        sq_en = 1'b0; set_vd(0.4); #20;
        chk("squelch, en = 0", squelch, 1'b1);
        sq_en = 1'b1; set_vd(0.0); #20;

        $display("[4] Disconnect");
        set_vd(0.4); #20; chk("disc at 400 mV", disc, 1'b0);
        set_vd(0.5); #20; chk("disc at 500 mV", disc, 1'b0);
        set_vd(0.65); #3; chk("disc after 3 ns at 650 mV", disc, 1'b0);
        #2; chk("disc after 5 ns at 650 mV", disc, 1'b1);
        set_vd(0.8); #10; chk("disc at 800 mV", disc, 1'b1);
        set_vd(0.0); #1;  chk("disc cleared", disc, 1'b0);
        sq_en = 1'b0; set_vd(0.8); #10; chk("disc, en = 0", disc, 1'b0);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
