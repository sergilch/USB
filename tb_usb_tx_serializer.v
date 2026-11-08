//-----------------------------------------------------------------------------
// tb_usb_tx_serializer.v - self-checking testbench for usb_tx_serializer
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim usb_tx_serializer.v tb_usb_tx_serializer.v
//   vvp sim
//
// The bench builds the expected line-bit stream (data bits + EOP) while it
// sends words, and a monitor samples the DUT outputs in the middle of every
// bit time and compares them, including the total packet length in clk_bit
// cycles (so gaps or wrong bit times are detected).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_tx_serializer;

    parameter real    HALF   = 1.042;   // ~480 MHz
    parameter integer FS_DIV = 40;
    parameter integer LS_DIV = 320;

    // ---------------- clock, reset, ce60 ----------------
    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;

    reg        rst_n;
    reg [2:0]  ce_cnt;
    wire       ce60 = (ce_cnt == 3'd7);

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) ce_cnt <= 3'd0;
        else        ce_cnt <= ce_cnt + 3'd1;
    end

    // ---------------- DUT ----------------
    reg  [1:0] speed;
    reg        in_valid;
    wire       in_ready;
    reg  [7:0] in_data;
    reg  [3:0] in_nbits;
    reg        in_last;
    wire       txd, tx_en, tx_se0;
    wire [1:0] tx_speed;
    wire       busy, tx_done, tx_underrun;

    usb_tx_serializer #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) dut (
        .clk_bit    (clk_bit),
        .rst_n      (rst_n),
        .ce60       (ce60),
        .speed      (speed),
        .in_valid   (in_valid),
        .in_ready   (in_ready),
        .in_data    (in_data),
        .in_nbits   (in_nbits),
        .in_last    (in_last),
        .txd        (txd),
        .tx_en      (tx_en),
        .tx_se0     (tx_se0),
        .tx_speed   (tx_speed),
        .busy       (busy),
        .tx_done    (tx_done),
        .tx_underrun(tx_underrun)
    );

    // ---------------- expected data ----------------
    reg     exp_bit [0:4095];
    reg     exp_se0 [0:4095];
    integer exp_len;
    reg     exp_last;
    integer cur_div;
    reg [1:0] cur_spd;

    integer errors         = 0;
    integer pkts_expected  = 0;
    integer pkts_checked   = 0;
    integer done_cnt       = 0;
    integer underrun_cnt   = 0;
    integer underrun_exp   = 0;

    // ---------------- monitor ----------------
    reg     capturing = 1'b0;
    integer cyc       = 0;
    integer cap_len   = 0;
    integer k;
    reg     cap_bit [0:4095];
    reg     cap_se0 [0:4095];

    always @(posedge clk_bit) begin
        if (rst_n) begin
            if (tx_se0 && !tx_en) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_se0 asserted while tx_en = 0", $time);
            end
            if (tx_done)     done_cnt     = done_cnt + 1;
            if (tx_underrun) underrun_cnt = underrun_cnt + 1;

            if (tx_en) begin
                if (!capturing) begin
                    capturing = 1'b1;
                    cyc       = 0;
                    cap_len   = 0;
                    if (tx_speed !== cur_spd) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: tx_speed = %b, expected %b", $time, tx_speed, cur_spd);
                    end
                end
                if ((cyc % cur_div) == (cur_div / 2)) begin
                    cap_bit[cap_len] = txd;
                    cap_se0[cap_len] = tx_se0;
                    cap_len = cap_len + 1;
                end
                cyc = cyc + 1;
            end else if (capturing) begin
                capturing = 1'b0;
                // ---- compare ----
                if (cyc != exp_len * cur_div) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: packet length %0d cycles, expected %0d (%0d bits x %0d)",
                             $time, cyc, exp_len * cur_div, exp_len, cur_div);
                end
                if (cap_len != exp_len) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: captured %0d bits, expected %0d", $time, cap_len, exp_len);
                end else begin
                    for (k = 0; k < exp_len; k = k + 1) begin
                        if (cap_se0[k] !== exp_se0[k]) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: bit %0d tx_se0 = %b, expected %b", $time, k, cap_se0[k], exp_se0[k]);
                        end else if (!exp_se0[k] && (cap_bit[k] !== exp_bit[k])) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: bit %0d txd = %b, expected %b", $time, k, cap_bit[k], exp_bit[k]);
                        end
                    end
                end
                pkts_checked = pkts_checked + 1;
            end
        end
    end

    // ---------------- tasks ----------------
    task begin_packet(input [1:0] spd);
        begin
            speed    = spd;
            cur_spd  = spd;
            exp_len  = 0;
            exp_last = 1'b1;               // line idles in J
            case (spd)
                2'b00:   cur_div = 1;
                2'b10:   cur_div = LS_DIV;
                default: cur_div = FS_DIV;
            endcase
            pkts_expected = pkts_expected + 1;
        end
    endtask

    task add_bits(input [7:0] d, input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                exp_bit[exp_len] = d[i];
                exp_se0[exp_len] = 1'b0;
                exp_len          = exp_len + 1;
                exp_last         = d[i];
            end
        end
    endtask

    task add_eop;
        integer i;
        begin
            if (cur_spd == 2'b00) begin
                for (i = 0; i < 8; i = i + 1) begin
                    exp_bit[exp_len] = ~exp_last;
                    exp_se0[exp_len] = 1'b0;
                    exp_len          = exp_len + 1;
                end
            end else begin
                exp_bit[exp_len] = 1'b0; exp_se0[exp_len] = 1'b1; exp_len = exp_len + 1;
                exp_bit[exp_len] = 1'b0; exp_se0[exp_len] = 1'b1; exp_len = exp_len + 1;
                exp_bit[exp_len] = 1'b1; exp_se0[exp_len] = 1'b0; exp_len = exp_len + 1;
            end
        end
    endtask

    // Send one word; the transfer happens on the clk_bit edge with ce60 && in_ready.
    task send_word(input [7:0] d, input [3:0] nb, input last);
        reg     accepted;
        integer n;
        begin
            n = last ? nb : 8;
            add_bits(d, n);
            @(negedge clk_bit);
            in_data  = d;
            in_nbits = nb;
            in_last  = last;
            in_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk_bit);
                if (ce60 && in_ready) accepted = 1'b1;   // pre-edge values
            end
            @(negedge clk_bit);
            in_valid = 1'b0;
            if (last) begin
                add_eop;
                if (in_ready !== 1'b0) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: in_ready not low after the last word", $time);
                end
            end
        end
    endtask

    task end_wait;
        begin
            wait (pkts_checked == pkts_expected);
            repeat (6) @(posedge clk_bit);
        end
    endtask

    // ---------------- stimulus ----------------
    integer seed = 32'h1234_5678;
    integer p, w, nw, nb, dat, spd_i;

    initial begin
        $dumpfile("tb_usb_tx_serializer.vcd");
        $dumpvars(0, tb_usb_tx_serializer);

        cur_div  = 1;
        cur_spd  = 2'b00;
        exp_len  = 0;
        exp_last = 1'b1;
        rst_n    = 1'b0;
        speed    = 2'b00;
        in_valid = 1'b0;
        in_data  = 8'd0;
        in_nbits = 4'd0;
        in_last  = 1'b0;

        repeat (5) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (10) @(posedge clk_bit);

        // ---- T1: HS, 4 full words ----
        $display("T1: HS packet, 4 words");
        begin_packet(2'b00);
        send_word(8'hA5, 4'd8, 1'b0);
        send_word(8'h3C, 4'd8, 1'b0);
        send_word(8'hFF, 4'd8, 1'b0);
        send_word(8'h81, 4'd8, 1'b1);
        end_wait;

        // ---- T2: HS, partial last word (5 bits, last bit 1) ----
        $display("T2: HS packet, last word 5 bits");
        begin_packet(2'b00);
        send_word(8'hF0, 4'd8, 1'b0);
        send_word(8'h1F, 4'd5, 1'b1);
        end_wait;

        // ---- T3: HS, single 1-bit word (last bit 0) ----
        $display("T3: HS packet, single 1-bit word");
        begin_packet(2'b00);
        send_word(8'h00, 4'd1, 1'b1);
        end_wait;

        // ---- T4: HS, EOP only ----
        $display("T4: HS EOP only");
        begin_packet(2'b00);
        send_word(8'h00, 4'd0, 1'b1);
        end_wait;

        // ---- T5: in_nbits must be ignored for non-last words ----
        $display("T5: in_nbits ignored on non-last word");
        begin_packet(2'b00);
        send_word(8'h96, 4'd3, 1'b0);
        send_word(8'h69, 4'd8, 1'b1);
        end_wait;

        // ---- T6: FS, 3 words ----
        $display("T6: FS packet, 3 words");
        begin_packet(2'b01);
        send_word(8'h80, 4'd8, 1'b0);
        send_word(8'hC3, 4'd8, 1'b0);
        send_word(8'hE1, 4'd8, 1'b1);
        end_wait;

        // ---- T7: FS, last word 3 bits ----
        $display("T7: FS packet, last word 3 bits");
        begin_packet(2'b01);
        send_word(8'h5A, 4'd8, 1'b0);
        send_word(8'h05, 4'd3, 1'b1);
        end_wait;

        // ---- T8: FS, EOP only (keep-alive style) ----
        $display("T8: FS EOP only");
        begin_packet(2'b01);
        send_word(8'h00, 4'd0, 1'b1);
        end_wait;

        // ---- T9: LS, 2 words ----
        $display("T9: LS packet, 2 words");
        begin_packet(2'b10);
        send_word(8'hA3, 4'd8, 1'b0);
        send_word(8'h5C, 4'd8, 1'b1);
        end_wait;

        // ---- T10: LS, single 4-bit word ----
        $display("T10: LS packet, single 4-bit word");
        begin_packet(2'b10);
        send_word(8'h0B, 4'd4, 1'b1);
        end_wait;

        // ---- T11: HS underrun ----
        $display("T11: HS underrun");
        begin_packet(2'b00);
        underrun_exp = underrun_exp + 1;
        send_word(8'hC3, 4'd8, 1'b0);
        add_eop;                           // aborted packet still ends with EOP
        end_wait;

        // ---- T12: FS underrun ----
        $display("T12: FS underrun");
        begin_packet(2'b01);
        underrun_exp = underrun_exp + 1;
        send_word(8'h3D, 4'd8, 1'b0);
        add_eop;
        end_wait;

        // ---- T13: random HS and FS packets ----
        $display("T13: random packets");
        for (p = 0; p < 12; p = p + 1) begin
            nw    = 1 + ({$random(seed)} % 10);
            spd_i = ((p % 3) == 2) ? 1 : 0;       // every third packet is FS
            begin_packet(spd_i[1:0]);
            for (w = 0; w < nw; w = w + 1) begin
                dat = $random(seed);
                if (spd_i == 1)                   // random pauses (FS only, no underrun)
                    repeat ({$random(seed)} % 100) @(posedge clk_bit);
                if (w == nw - 1) begin
                    nb = 1 + ({$random(seed)} % 8);
                    send_word(dat[7:0], nb[3:0], 1'b1);
                end else begin
                    send_word(dat[7:0], 4'd8, 1'b0);
                end
            end
            end_wait;
        end

        // ---- final checks ----
        repeat (20) @(posedge clk_bit);
        if (done_cnt != pkts_expected) begin
            errors = errors + 1;
            $display("ERROR: tx_done pulses = %0d, packets = %0d", done_cnt, pkts_expected);
        end
        if (underrun_cnt != underrun_exp) begin
            errors = errors + 1;
            $display("ERROR: tx_underrun pulses = %0d, expected %0d", underrun_cnt, underrun_exp);
        end
        if (busy !== 1'b0 || tx_en !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not idle at the end");
        end

        $display("--------------------------------------------------");
        $display("Packets checked: %0d, tx_done: %0d, underruns: %0d", pkts_checked, done_cnt, underrun_cnt);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    // watchdog
    initial begin
        #5_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
