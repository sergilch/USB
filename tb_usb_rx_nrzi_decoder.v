//-----------------------------------------------------------------------------
// tb_usb_rx_nrzi_decoder.v - self-checking testbench for usb_rx_nrzi_decoder
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxnrzi usb_rx_nrzi_decoder.v tb_usb_rx_nrzi_decoder.v
//   vvp sim_rxnrzi
//
// Packets are NRZI-encoded in the testbench (0 = change, 1 = no change,
// starting from J) and sent with random bit strobe gaps, idle J between them,
// optional SE0 EOPs and receiver-inactive stretches.  Checked:
//   * the decoded bits of every packet equal the data bits (round trip);
//   * directed: FS SYNC KJKJKJKK from idle J decodes as 0000 0001;
//   * the reference level returns to J after SE0 and after inactive bits;
//   * o_en is i_en delayed by one cycle; o_se0 / o_act are passed through;
//   * outputs only change with a strobe.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_nrzi_decoder;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n;

    reg  i_en = 1'b0, i_lvl = 1'b1, i_se0 = 1'b0, i_act = 1'b0;
    wire o_en, o_bit, o_se0, o_act;

    usb_rx_nrzi_decoder dut (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_lvl (i_lvl), .i_se0 (i_se0), .i_act (i_act),
        .o_en (o_en), .o_bit (o_bit), .o_se0 (o_se0), .o_act (o_act)
    );

    integer errors = 0;
    integer seed   = 32'h1357_9BDF;
    integer nbits_checked = 0;
    reg     gaps = 1'b1;

    // expected output of the last strobe
    reg     x_valid = 1'b0;
    reg     x_bit, x_se0, x_act, x_chk;

    // previous output values for the "only change with a strobe" check
    reg     p_bit, p_se0, p_act;

    always @(posedge clk) begin
        if (rst_n) begin
            if (o_en !== x_valid) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_en = %b, expected %b", $time, o_en, x_valid);
            end
            if (o_en && x_valid) begin
                if ((o_se0 !== x_se0) || (o_act !== x_act)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: se0/act not passed through", $time);
                end
                if (x_chk) begin
                    nbits_checked = nbits_checked + 1;
                    if (o_bit !== x_bit) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: decoded %b, expected %b", $time, o_bit, x_bit);
                    end
                end
            end
            if (!o_en && ((o_bit !== p_bit) || (o_se0 !== p_se0) || (o_act !== p_act))) begin
                errors = errors + 1;
                $display("ERROR @%0t: outputs changed without a strobe", $time);
            end
            p_bit = o_bit; p_se0 = o_se0; p_act = o_act;
        end
    end

    // drive one strobe; chk: compare the decoded bit with b
    task bit_out(input lvl, input se0, input act, input b, input chk);
        begin
            while (gaps && ({$random(seed)} % 3 == 0)) begin
                @(negedge clk);
                i_en    = 1'b0;
                i_lvl   = $random(seed);              // garbage between strobes
                @(posedge clk);
                #0.1;
                x_valid = 1'b0;
            end
            @(negedge clk);
            i_en  = 1'b1;
            i_lvl = lvl;
            i_se0 = se0;
            i_act = act;
            @(posedge clk);
            #0.1;
            x_valid = 1'b1;
            x_bit   = b;
            x_se0   = se0;
            x_act   = act;
            x_chk   = chk;
        end
    endtask

    reg line = 1'b1;                               // current line level (J at idle)

    task idle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                bit_out(1'b1, 1'b0, 1'b1, line, 1'b1);     // J: 1 if the line was J, 0 after K
                line = 1'b1;
            end
        end
    endtask

    task data_bits(input integer n);
        integer i;
        reg b;
        begin
            for (i = 0; i < n; i = i + 1) begin
                b = ({$random(seed)} % 3) != 0;
                if (!b) line = ~line;
                bit_out(line, 1'b0, 1'b1, b, 1'b1);
            end
        end
    endtask

    task se0_eop;
        begin
            bit_out(1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
            bit_out(1'b1, 1'b1, 1'b1, 1'b0, 1'b0);   // level ignored during SE0
            line = 1'b1;
            bit_out(1'b1, 1'b0, 1'b1, 1'b1, 1'b1);   // J after SE0 -> 1
        end
    endtask

    task inactive(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) bit_out($random(seed), 1'b0, 1'b0, 1'b0, 1'b0);
            line = 1'b1;
        end
    endtask

    integer p, k;

    initial begin
        $dumpfile("tb_usb_rx_nrzi_decoder.vcd");
        $dumpvars(0, tb_usb_rx_nrzi_decoder);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        @(posedge clk);
        p_bit = o_bit; p_se0 = o_se0; p_act = o_act;

        $display("Directed FS SYNC from idle J");
        gaps = 1'b0;
        idle(4);
        for (k = 0; k < 7; k = k + 1) begin               // K J K J K J K -> 0 x 7
            line = ~line;
            bit_out(line, 1'b0, 1'b1, 1'b0, 1'b1);
        end
        bit_out(line, 1'b0, 1'b1, 1'b1, 1'b1);            // K K -> 1
        se0_eop;

        $display("First bit after inactive / SE0: reference is J");
        inactive(3);
        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1);            // K after inactive -> 0
        line = 1'b0;
        se0_eop;
        bit_out(1'b0, 1'b0, 1'b1, 1'b0, 1'b1);            // K after SE0 + J -> 0
        line = 1'b0;

        $display("Random packets with strobe gaps");
        gaps = 1'b1;
        for (p = 0; p < 300; p = p + 1) begin
            idle(1 + {$random(seed)} % 4);
            data_bits(1 + {$random(seed)} % 60);
            case ({$random(seed)} % 3)
                0: se0_eop;
                1: inactive(1 + {$random(seed)} % 3);
                default: ;
            endcase
        end

        @(negedge clk) i_en = 1'b0;
        @(posedge clk); #0.1;
        x_valid = 1'b0;
        repeat (5) @(posedge clk);
        $display("%0d bits checked", nbits_checked);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
