//-----------------------------------------------------------------------------
// tb_usb_rx_hs_frontend.v - self-checking testbench for usb_rx_hs_frontend
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxhsfe usb_rx_hs_frontend.v tb_usb_rx_hs_frontend.v
//   vvp sim_rxhsfe
//
// Random data on rxd every recovered clock; squelch, cdr_lock and enable change
// at random times (between clock edges, as asynchronous signals would).
// Checked, against a history of the values present at each clk_rx edge:
//   * b_en = 1 in every cycle after reset, b_se0 = 0;
//   * b_lvl = rxd of 3 edges earlier;
//   * b_act = !squelch && cdr_lock && enable of 3 edges earlier, i.e. data and
//     qualifier stay aligned through the synchronizers;
//   * after reset b_act = 0 until the qualifiers have been seen.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_hs_frontend;

    reg clk_rx = 1'b0;
    always #1.0416667 clk_rx = ~clk_rx;
    reg rst_n;

    reg  rxd = 1'b1, squelch = 1'b1, cdr_lock = 1'b0, enable = 1'b0;
    wire b_en, b_lvl, b_se0, b_act;

    usb_rx_hs_frontend dut (
        .clk_rx (clk_rx), .rst_n (rst_n),
        .rxd (rxd), .squelch (squelch), .cdr_lock (cdr_lock), .enable (enable),
        .b_en (b_en), .b_lvl (b_lvl), .b_se0 (b_se0), .b_act (b_act)
    );

    integer errors = 0;
    integer seed   = 32'h4855_0001;

    reg     h_d [0:1048575];
    reg     h_q [0:1048575];
    integer k = 0, nact = 0, nchk = 0;

    always @(posedge clk_rx) begin
        if (rst_n) begin
            h_d[k] = rxd;
            h_q[k] = !squelch && cdr_lock && enable;
            if (k >= 4) begin
                nchk = nchk + 1;
                if (b_en !== 1'b1 || b_se0 !== 1'b0) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: b_en = %b, b_se0 = %b", $time, b_en, b_se0);
                end
                if (b_lvl !== h_d[k - 3]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: b_lvl = %b, expected %b", $time, b_lvl, h_d[k - 3]);
                end
                if (b_act !== h_q[k - 3]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: b_act = %b, expected %b", $time, b_act, h_q[k - 3]);
                end
                if (b_act) nact = nact + 1;
            end else if (b_act) begin
                errors = errors + 1;
                $display("ERROR @%0t: b_act right after reset", $time);
            end
            k = k + 1;
        end
    end

    // data: changes right after the edge
    always @(posedge clk_rx) rxd <= #0.2 $random(seed);

    // qualifiers: change at random times between the clock edges (just after a
    // falling edge, so never at the sampling edge)
    initial begin
        #30;
        forever begin
            repeat ({$random(seed)} % 12) @(negedge clk_rx);
            #(0.1 + ({$random(seed)} % 6) / 10.0);
            case ({$random(seed)} % 3)
                0: squelch  = $random(seed);
                1: cdr_lock = ({$random(seed)} % 4) != 0;
                2: enable   = ({$random(seed)} % 4) != 0;
            endcase
        end
    end

    initial begin
        $dumpfile("tb_usb_rx_hs_frontend.vcd");
        $dumpvars(0, tb_usb_rx_hs_frontend);
        rst_n = 1'b0;
        #10.3 rst_n = 1'b1;
        #65000;
        $display("%0d cycles checked, b_act high in %0d", nchk, nact);
        if (nact < 1000) begin
            errors = errors + 1;
            $display("ERROR: b_act hardly ever high");
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
