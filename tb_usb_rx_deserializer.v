//-----------------------------------------------------------------------------
// tb_usb_rx_deserializer.v - self-checking testbench for usb_rx_deserializer
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxdes usb_rx_deserializer.v tb_usb_rx_deserializer.v
//   vvp sim_rxdes
//
// Packets of random bytes are sent bit by bit (LSB first) after a SYNC strobe,
// with non-data bits (stuff positions, i_dat = 0) and strobe gaps mixed in, and
// some packets end with 1..7 extra bits.  A new SYNC in the middle of a byte
// must restart the alignment.  Checked:
//   * o_byte_en / o_byte exactly once per 8 data bits, with the right value;
//   * o_nres = data bits held after every strobe (0 after SYNC);
//   * sideband (en, serr, se0, act, sync) passed through with one cycle of latency;
//   * no output byte without a strobe.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_deserializer;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n;

    reg  i_en = 1'b0, i_dat = 1'b0, i_bit = 1'b0, i_serr = 1'b0, i_se0 = 1'b0, i_act = 1'b1, i_sync = 1'b0;
    wire o_en, o_byte_en, o_serr, o_se0, o_act, o_sync;
    wire [7:0] o_byte;
    wire [2:0] o_nres;

    usb_rx_deserializer dut (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_dat (i_dat), .i_bit (i_bit), .i_serr (i_serr),
        .i_se0 (i_se0), .i_act (i_act), .i_sync (i_sync),
        .o_en (o_en), .o_byte_en (o_byte_en), .o_byte (o_byte), .o_nres (o_nres),
        .o_serr (o_serr), .o_se0 (o_se0), .o_act (o_act), .o_sync (o_sync)
    );

    integer errors = 0;
    integer seed   = 32'h0F0F_7777;
    integer bytes_ok = 0;

    reg       x_valid = 1'b0, x_byte_en, x_serr, x_se0, x_act, x_sync;
    reg [7:0] x_byte;
    reg [2:0] x_nres;
    reg       y_byte_en, y_serr, y_se0, y_sync;           // staged for the next edge
    reg [7:0] y_byte;
    reg [2:0] y_nres;

    always @(posedge clk) begin
        if (rst_n) begin
            if (o_en !== x_valid) begin
                errors = errors + 1;
                $display("ERROR @%0t: o_en wrong", $time);
            end
            if (!o_en && o_byte_en) begin
                errors = errors + 1;
                $display("ERROR @%0t: byte without a strobe", $time);
            end
            if (x_valid) begin
                if ((o_serr !== x_serr) || (o_se0 !== x_se0) || (o_act !== x_act) || (o_sync !== x_sync)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: sideband not passed through", $time);
                end
                if (o_nres !== x_nres) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: nres = %0d, expected %0d", $time, o_nres, x_nres);
                end
                if (o_byte_en !== x_byte_en) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: byte_en = %b, expected %b", $time, o_byte_en, x_byte_en);
                end else if (x_byte_en) begin
                    if (o_byte !== x_byte) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: byte %02h, expected %02h", $time, o_byte, x_byte);
                    end else begin
                        bytes_ok = bytes_ok + 1;
                    end
                end
            end
        end
    end

    // model state
    integer   m_n = 0;
    reg [7:0] m_sh = 8'd0;

    task strobe(input dat, input b, input sync, input serr, input se0);
        begin
            if ({$random(seed)} % 4 == 0) begin
                @(negedge clk);
                i_en = 1'b0; i_dat = $random(seed); i_bit = $random(seed);
                @(posedge clk); #0.1;
                x_valid = 1'b0;
            end
            @(negedge clk);
            i_en = 1'b1; i_dat = dat; i_bit = b; i_sync = sync; i_serr = serr; i_se0 = se0;
            i_act = 1'b1;
            y_byte_en = 1'b0;
            if (sync) begin
                m_n = 0;
            end else if (dat) begin
                m_sh[m_n] = b;
                m_n = m_n + 1;
                if (m_n == 8) begin
                    y_byte_en = 1'b1;
                    y_byte    = m_sh;
                    m_n       = 0;
                end
            end
            y_nres = m_n;
            y_serr = serr; y_se0 = se0; y_sync = sync;
            @(posedge clk); #0.1;
            x_valid = 1'b1;
            x_byte_en = y_byte_en; x_byte = y_byte; x_nres = y_nres;
            x_serr = y_serr; x_se0 = y_se0; x_act = 1'b1; x_sync = y_sync;
        end
    endtask

    task packet(input integer nbytes, input integer extra);
        integer i, j;
        reg [7:0] v;
        begin
            strobe(1'b0, 1'b1, 1'b1, 1'b0, 1'b0);               // SYNC
            for (i = 0; i < nbytes; i = i + 1) begin
                v = $random(seed);
                for (j = 0; j < 8; j = j + 1) begin
                    if ({$random(seed)} % 6 == 0)
                        strobe(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);   // stuff bit (not data)
                    strobe(1'b1, v[j], 1'b0, 1'b0, 1'b0);
                end
            end
            for (j = 0; j < extra; j = j + 1)
                strobe(1'b1, $random(seed), 1'b0, 1'b0, 1'b0);
            if ({$random(seed)} % 2) strobe(1'b0, 1'b1, 1'b0, 1'b1, 1'b0);   // HS-style violation
            else                     strobe(1'b0, 1'b0, 1'b0, 1'b0, 1'b1);   // SE0
        end
    endtask

    integer p;

    initial begin
        $dumpfile("tb_usb_rx_deserializer.vcd");
        $dumpvars(0, tb_usb_rx_deserializer);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        $display("Random packets");
        for (p = 0; p < 300; p = p + 1)
            packet({$random(seed)} % 20, ({$random(seed)} % 3 == 0) ? 1 + {$random(seed)} % 7 : 0);

        $display("SYNC inside a byte restarts the alignment");
        strobe(1'b1, 1'b1, 1'b0, 1'b0, 1'b0);
        strobe(1'b1, 1'b0, 1'b0, 1'b0, 1'b0);
        strobe(1'b1, 1'b1, 1'b0, 1'b0, 1'b0);
        packet(4, 0);

        @(negedge clk) i_en = 1'b0;
        @(posedge clk); #0.1;
        x_valid = 1'b0;
        repeat (5) @(posedge clk);
        $display("%0d bytes checked", bytes_ok);
        if (bytes_ok < 2000) begin
            errors = errors + 1;
            $display("ERROR: not enough bytes");
        end
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
