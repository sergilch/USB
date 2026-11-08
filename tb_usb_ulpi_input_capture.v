//-----------------------------------------------------------------------------
// tb_usb_ulpi_input_capture.v - self-checking testbench for usb_ulpi_input_capture
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_cap usb_ulpi_input_capture.v tb_usb_ulpi_input_capture.v
//   vvp sim_cap
//
// Checks
//   1. Alignment and bus-ownership qualification: the captured byte, STP and nxt_seen
//      describe the pins of the previous tick; lnk_valid is high only if DIR was low in
//      that tick AND in the tick before it (turnaround).  A hard-coded DIR pattern with
//      all the interesting transitions is used; stp_raw (combinational, current tick)
//      follows the same rule.
//      stp_abort (STP while the PHY owned the bus) follows the mirrored rule.
//   2. The command decode for all 256 byte values (NOOP, TXCMD 40h-4Fh, register write
//      80h-BFh, register read C0h-FFh, extended AFh / EFh) and that nothing is decoded
//      when the Link did not own the bus.
//   3. Clock enable: with ce = 0 nothing changes, a single ce tick captures the pins.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_input_capture;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    reg ce = 1'b1;

    reg [7:0] data_in = 8'd0;
    reg       stp_in  = 1'b0;
    reg       dir_q   = 1'b0;
    reg       nxt_q   = 1'b0;

    wire       lnk_valid, lnk_stp, nxt_seen, stp_raw, stp_abort;
    wire [7:0] lnk_data;
    wire       cmd_noop, cmd_tx, cmd_regw, cmd_regr, cmd_ext;
    wire [3:0] cmd_pid;
    wire [5:0] cmd_addr;

    usb_ulpi_input_capture dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .data_in   (data_in),
        .stp_in    (stp_in),
        .dir_q     (dir_q),
        .nxt_q     (nxt_q),
        .lnk_valid (lnk_valid),
        .lnk_data  (lnk_data),
        .lnk_stp   (lnk_stp),
        .nxt_seen  (nxt_seen),
        .stp_raw   (stp_raw),
        .stp_abort (stp_abort),
        .cmd_noop  (cmd_noop),
        .cmd_tx    (cmd_tx),
        .cmd_pid   (cmd_pid),
        .cmd_regw  (cmd_regw),
        .cmd_regr  (cmd_regr),
        .cmd_ext   (cmd_ext),
        .cmd_addr  (cmd_addr)
    );

    integer errors = 0;

    // hard-coded DIR pattern and the expected lnk_valid for the captured tick
    reg       dseq [0:11];
    reg       vexp [0:11];
    reg       pexp [0:11];                // expected stp_abort (PHY owned the bus now and before)

    integer t, v;
    reg     prev_d;
    reg     exp_valid;
    reg     e_noop, e_tx, e_regw, e_regr, e_ext;

    task fail(input [255:0] what);
        begin
            errors = errors + 1;
            $display("ERROR @%0t: %0s", $time, what);
        end
    endtask

    initial begin
        $dumpfile("tb_usb_ulpi_input_capture.vcd");
        $dumpvars(0, tb_usb_ulpi_input_capture);

        // DIR:        0 0 1 1 0 0 0 1 0 1 0 0
        dseq[0]=0; dseq[1]=0; dseq[2]=1; dseq[3]=1; dseq[4]=0; dseq[5]=0;
        dseq[6]=0; dseq[7]=1; dseq[8]=0; dseq[9]=1; dseq[10]=0; dseq[11]=0;
        // stp_abort:  0 0 0 1 0 0 0 0 0 0 0 0   (DIR high now and in the tick before, STP = 1)
        pexp[0]=0; pexp[1]=0; pexp[2]=0; pexp[3]=1; pexp[4]=0; pexp[5]=0;
        pexp[6]=0; pexp[7]=0; pexp[8]=0; pexp[9]=0; pexp[10]=0; pexp[11]=0;
        // lnk_valid:  1 1 0 0 0 1 1 0 0 0 0 1   (DIR low now and in the tick before)
        vexp[0]=1; vexp[1]=1; vexp[2]=0; vexp[3]=0; vexp[4]=0; vexp[5]=1;
        vexp[6]=1; vexp[7]=0; vexp[8]=0; vexp[9]=0; vexp[10]=0; vexp[11]=1;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        // ---------------- 1. alignment and qualification ----------------
        $display("T1: alignment and DIR qualification");
        for (t = 0; t < 12; t = t + 1) begin
            @(negedge clk);
            dir_q   = dseq[t];
            stp_in  = 1'b1;
            data_in = t + 1;
            nxt_q   = t[0];
            #1;
            prev_d = (t == 0) ? 1'b0 : dseq[t - 1];
            if (stp_raw !== (stp_in && !dseq[t] && !prev_d)) fail("stp_raw");
            @(posedge clk);
            #1;
            if (lnk_valid !== vexp[t])                        fail("lnk_valid");
            if (lnk_data  !== (t + 1))                        fail("lnk_data (not the captured byte)");
            if (lnk_stp   !== (vexp[t] && 1'b1))              fail("lnk_stp");
            if (stp_abort !== pexp[t])                        fail("stp_abort");
            if (nxt_seen  !== t[0])                           fail("nxt_seen (not the NXT of the captured tick)");
        end

        // ---------------- 2. command decode, all byte values ----------------
        $display("T2: command decode");
        @(negedge clk);
        dir_q = 1'b0;
        stp_in = 1'b0;
        repeat (3) @(posedge clk);                            // lnk_valid is stable high
        for (v = 0; v < 256; v = v + 1) begin
            @(negedge clk);
            data_in = v;
            @(posedge clk);
            #1;
            e_noop = (v == 8'h00);
            e_tx   = (v >= 8'h40) && (v <= 8'h4F);
            e_regw = (v >= 8'h80) && (v <= 8'hBF);
            e_regr = (v >= 8'hC0);
            e_ext  = (v == 8'hAF) || (v == 8'hEF);
            if (lnk_valid !== 1'b1)       fail("lnk_valid low with DIR low");
            if (cmd_noop !== e_noop)      begin fail("cmd_noop"); $display("   byte %02h", v); end
            if (cmd_tx   !== e_tx)        begin fail("cmd_tx");   $display("   byte %02h", v); end
            if (cmd_regw !== e_regw)      begin fail("cmd_regw"); $display("   byte %02h", v); end
            if (cmd_regr !== e_regr)      begin fail("cmd_regr"); $display("   byte %02h", v); end
            if (cmd_ext  !== e_ext)       begin fail("cmd_ext");  $display("   byte %02h", v); end
            if (cmd_pid  !== v[3:0])      fail("cmd_pid");
            if (cmd_addr !== v[5:0])      fail("cmd_addr");
        end

        // nothing is decoded when the PHY owned the bus (DIR high)
        @(negedge clk);
        dir_q = 1'b1;
        data_in = 8'h40;
        repeat (3) @(posedge clk);
        #1;
        if (lnk_valid !== 1'b0) fail("lnk_valid high with DIR high");
        if (cmd_tx || cmd_regw || cmd_regr || cmd_noop || cmd_ext) fail("command decoded while the PHY owned the bus");

        // ---------------- 3. clock enable ----------------
        $display("T3: clock enable");
        @(negedge clk);
        dir_q = 1'b0;
        stp_in = 1'b0;
        nxt_q = 1'b0;
        data_in = 8'h12;
        repeat (3) @(posedge clk);                            // settle, valid high
        @(negedge clk);
        ce      = 1'b0;
        data_in = 8'h34;
        stp_in  = 1'b1;
        nxt_q   = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if (lnk_data !== 8'h12 || lnk_stp !== 1'b0 || nxt_seen !== 1'b0) fail("capture registers changed with ce = 0");
        @(negedge clk);
        ce = 1'b1;
        @(posedge clk);
        #1;
        if (lnk_data !== 8'h34 || lnk_stp !== 1'b1 || nxt_seen !== 1'b1) fail("single ce tick did not capture the pins");
        @(negedge clk);
        ce = 1'b0;

        $display("--------------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
