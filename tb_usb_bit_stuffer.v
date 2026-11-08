//-----------------------------------------------------------------------------
// tb_usb_bit_stuffer.v - self-checking testbench for usb_bit_stuffer
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_bs usb_bit_stuffer.v tb_usb_bit_stuffer.v
//   vvp sim_bs
//
// Every packet is checked twice:
//   1) against a reference model that stuffs the source bytes bit by bit;
//   2) by an independent de-stuffer that works on the captured bit stream
//      (a 0 must follow every run of six 1s, including at the very end of
//      the packet) and must give back the source bits.
// In addition the monitor checks the word format (8 bits, last word 1..8),
// output stability while out_valid && !out_ready, the accumulator limit, the
// full input throughput of a stuffing-free stream and (D11/D12) that the output
// never runs dry mid-packet when the input is continuous - the property the
// gapless HS serializer behind the stuffer depends on.
//
// The "ce" strobe, the output backpressure and the source gaps are varied:
//   ce_mode : 0 = always 1, 1 = one cycle in eight (clk_bit / ce60 style),
//             2 = random 50 %
//   ro_mode : out_ready 0 = always 1, 1 = random 50 %, 2 = random 25 %
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_bit_stuffer;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;

    // ---------------- DUT ----------------
    reg        ce        = 1'b1;
    reg        stuff_dis = 1'b0;
    reg        in_valid  = 1'b0;
    wire       in_ready;
    reg  [7:0] in_data   = 8'd0;
    reg        in_last   = 1'b0;
    wire       out_valid;
    reg        out_ready = 1'b1;
    wire [7:0] out_data;
    wire [3:0] out_nbits;
    wire       out_last;

    usb_bit_stuffer dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .stuff_dis (stuff_dis),
        .in_valid  (in_valid),
        .in_ready  (in_ready),
        .in_data   (in_data),
        .in_last   (in_last),
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (out_data),
        .out_nbits (out_nbits),
        .out_last  (out_last)
    );

    // ---------------- bookkeeping ----------------
    integer errors       = 0;
    integer pkts_sent    = 0;
    integer pkts_checked = 0;
    integer cyc_cnt      = 0;
    always @(posedge clk) cyc_cnt <= cyc_cnt + 1;

    integer ce_mode = 0;
    integer ro_mode = 0;
    integer ce_ph   = 0;
    integer seed_ce = 32'h1111_1111;
    integer seed_ro = 32'h2222_2222;
    integer seed    = 32'h3333_3333;

    // ce / out_ready are updated on the falling edge, so they are stable at
    // every rising edge where the DUT and the monitor sample them.
    always @(negedge clk) begin
        case (ce_mode)
            0: ce <= 1'b1;
            1: begin
                   ce    <= (ce_ph == 7);
                   ce_ph <= (ce_ph + 1) % 8;
               end
            default: ce <= (({$random(seed_ce)} % 2) == 1);
        endcase
        case (ro_mode)
            0: out_ready <= 1'b1;
            1: out_ready <= (({$random(seed_ro)} % 2) == 1);
            default: out_ready <= (({$random(seed_ro)} % 4) == 0);
        endcase
    end

    // ---------------- source packet and expected data ----------------
    reg [7:0] src_bytes [0:63];
    integer   src_len;
    reg       raw_b [0:511];    // source bits
    integer   raw_n;
    reg       exp_b [0:1023];   // expected stuffed bits
    integer   exp_n;
    reg       cur_dis;
    reg       chk_tp   = 1'b0;
    reg       chk_cont = 1'b0;   // output must be continuous inside a packet
    reg       pkt_active = 1'b0;
    integer   first_acc_cyc, last_acc_cyc;

    task pk_begin;
        begin
            src_len = 0;
        end
    endtask

    task pk_add(input [7:0] b);
        begin
            src_bytes[src_len] = b;
            src_len = src_len + 1;
        end
    endtask

    task build_expected(input dis);
        integer   i, j, c;
        reg [7:0] tb;
        begin
            exp_n = 0;
            raw_n = 0;
            c     = 0;
            for (i = 0; i < src_len; i = i + 1) begin
                tb = src_bytes[i];
                for (j = 0; j < 8; j = j + 1) begin
                    raw_b[raw_n] = tb[j];
                    raw_n        = raw_n + 1;
                    exp_b[exp_n] = tb[j];
                    exp_n        = exp_n + 1;
                    if (!dis) begin
                        if (tb[j]) begin
                            c = c + 1;
                            if (c == 6) begin            // stuff a 0
                                exp_b[exp_n] = 1'b0;
                                exp_n        = exp_n + 1;
                                c            = 0;
                            end
                        end else begin
                            c = 0;
                        end
                    end
                end
            end
        end
    endtask

    // Called at a falling edge; returns at the next falling edge after the
    // byte was accepted (in_valid stays high, so the caller can send the next
    // byte back-to-back).
    task send_byte(input [7:0] d, input last);
        reg accepted;
        begin
            in_data  = d;
            in_last  = last;
            in_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (ce && in_ready) begin          // pre-edge values
                    accepted     = 1'b1;
                    last_acc_cyc = cyc_cnt;
                end
            end
            @(negedge clk);
        end
    endtask

    task pk_send(input dis, input gaps);
        integer i;
        begin
            pkts_sent = pkts_sent + 1;
            cur_dis   = dis;
            @(negedge clk);
            stuff_dis = dis;
            for (i = 0; i < src_len; i = i + 1) begin
                if (gaps && (i != 0) && (({$random(seed)} % 3) == 0)) begin
                    in_valid = 1'b0;
                    repeat ({$random(seed)} % 12) @(negedge clk);
                end
                send_byte(src_bytes[i], (i == src_len - 1));
                if (i == 0) first_acc_cyc = last_acc_cyc;
            end
            build_expected(dis);        // done before the last word can appear
            in_valid = 1'b0;
            if (chk_tp && ((last_acc_cyc - first_acc_cyc) != (src_len - 1))) begin
                errors = errors + 1;
                $display("ERROR: throughput: %0d bytes accepted over %0d cycles",
                         src_len, last_acc_cyc - first_acc_cyc + 1);
            end
            wait (pkts_checked == pkts_sent);
            repeat (4) @(posedge clk);
        end
    endtask

    // ---------------- monitor ----------------
    reg       cap_b [0:1023];
    reg       dst_b [0:1023];
    integer   cap_n = 0;
    integer   im;
    reg       prev_valid = 1'b0;
    reg       prev_xfer  = 1'b0;
    reg [7:0] prev_data  = 8'd0;
    reg [3:0] prev_nb    = 4'd0;
    reg       prev_last  = 1'b0;

    task check_packet;
        integer i, c, dn;
        reg     mism;
        begin
            // 1) reference model
            if (cap_n != exp_n) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0d output bits, expected %0d", $time, cap_n, exp_n);
            end else begin
                mism = 1'b0;
                for (i = 0; i < exp_n; i = i + 1) begin
                    if (!mism && (cap_b[i] !== exp_b[i])) begin
                        mism   = 1'b1;
                        errors = errors + 1;
                        $display("ERROR @%0t: bit %0d = %b, expected %b", $time, i, cap_b[i], exp_b[i]);
                    end
                end
            end

            // 2) independent de-stuffing of the captured stream
            c  = 0;
            dn = 0;
            for (i = 0; i < cap_n; i = i + 1) begin
                if (cur_dis) begin
                    dst_b[dn] = cap_b[i];
                    dn        = dn + 1;
                end else if (c == 6) begin             // a stuffed 0 must come now
                    if (cap_b[i] !== 1'b0) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: bit %0d should be a stuffed 0", $time, i);
                    end
                    c = 0;
                end else begin
                    dst_b[dn] = cap_b[i];
                    dn        = dn + 1;
                    if (cap_b[i]) c = c + 1;
                    else          c = 0;
                end
            end
            if (!cur_dis && (c == 6)) begin
                errors = errors + 1;
                $display("ERROR @%0t: trailing stuff bit missing after six final ones", $time);
            end
            if (dn != raw_n) begin
                errors = errors + 1;
                $display("ERROR @%0t: de-stuffed %0d bits, source has %0d", $time, dn, raw_n);
            end else begin
                mism = 1'b0;
                for (i = 0; i < raw_n; i = i + 1) begin
                    if (!mism && (dst_b[i] !== raw_b[i])) begin
                        mism   = 1'b1;
                        errors = errors + 1;
                        $display("ERROR @%0t: de-stuffed bit %0d differs from the source", $time, i);
                    end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            // output must stay stable until it is accepted
            if (prev_valid && !prev_xfer) begin
                if (!out_valid || (out_data !== prev_data) ||
                    (out_nbits !== prev_nb) || (out_last !== prev_last)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: output changed while waiting for out_ready", $time);
                end
            end
            if (dut.acc_cnt > 5'd25) begin
                errors = errors + 1;
                $display("ERROR @%0t: accumulator overflow (%0d bits)", $time, dut.acc_cnt);
            end

            if (chk_cont && pkt_active && ce && !out_valid) begin
                errors = errors + 1;
                $display("ERROR @%0t: output ran dry inside a packet (acc_cnt = %0d)", $time, dut.acc_cnt);
            end

            if (ce && out_valid && out_ready) begin
                pkt_active = 1'b1;
                if (!out_last && (out_nbits != 4'd8)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: non-last word with %0d bits", $time, out_nbits);
                end
                if (out_last && ((out_nbits < 4'd1) || (out_nbits > 4'd8))) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: last word with %0d bits", $time, out_nbits);
                end
                for (im = 0; im < out_nbits; im = im + 1) begin
                    cap_b[cap_n] = out_data[im];
                    cap_n        = cap_n + 1;
                end
                if (out_last) begin
                    pkt_active   = 1'b0;
                    check_packet;
                    cap_n        = 0;
                    pkts_checked = pkts_checked + 1;
                end
            end

            prev_valid = out_valid;
            prev_xfer  = ce && out_valid && out_ready;
            prev_data  = out_data;
            prev_nb    = out_nbits;
            prev_last  = out_last;
        end
    end

    // ---------------- stimulus ----------------
    integer cm, rm, p, w, nbytes, rr;
    reg [7:0] bv;
    reg       dis_r;

    initial begin
        $dumpfile("tb_usb_bit_stuffer.vcd");
        $dumpvars(0, tb_usb_bit_stuffer);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---------------- directed, ce = 1, out_ready = 1 ----------------
        ce_mode = 0;
        ro_mode = 0;

        $display("D1: 00h (no stuffing)");
        pk_begin; pk_add(8'h00);
        pk_send(1'b0, 1'b0);

        $display("D2: FFh (9 bits)");
        pk_begin; pk_add(8'hFF);
        pk_send(1'b0, 1'b0);

        $display("D3: 7Eh (six ones in the middle)");
        pk_begin; pk_add(8'h7E);
        pk_send(1'b0, 1'b0);

        $display("D4: FCh (six ones at the very end -> trailing stuff bit)");
        pk_begin; pk_add(8'hFC);
        pk_send(1'b0, 1'b0);

        $display("D5: 3Fh (six ones first)");
        pk_begin; pk_add(8'h3F);
        pk_send(1'b0, 1'b0);

        $display("D6: FFh x4");
        pk_begin; pk_add(8'hFF); pk_add(8'hFF); pk_add(8'hFF); pk_add(8'hFF);
        pk_send(1'b0, 1'b0);

        $display("D7: SYNC 80h + 1Fh + AAh (run continues over the byte boundary)");
        pk_begin; pk_add(8'h80); pk_add(8'h1F); pk_add(8'hAA);
        pk_send(1'b0, 1'b0);

        $display("D8: F8h + FFh (two stuffed bits inside one byte)");
        pk_begin; pk_add(8'hF8); pk_add(8'hFF);
        pk_send(1'b0, 1'b0);

        $display("D9: FFh x3 with bit stuffing disabled");
        pk_begin; pk_add(8'hFF); pk_add(8'hFF); pk_add(8'hFF);
        pk_send(1'b1, 1'b0);

        $display("D10: full throughput, 16 x 55h back-to-back");
        pk_begin;
        for (w = 0; w < 16; w = w + 1) pk_add(8'h55);
        chk_tp = 1'b1;
        pk_send(1'b0, 1'b0);
        chk_tp = 1'b0;

        $display("D11: 40 x FFh, ce = 1 in 8, continuous input (no output bubbles)");
        ce_mode = 1;
        pk_begin;
        for (w = 0; w < 40; w = w + 1) pk_add(8'hFF);
        chk_cont = 1'b1;
        pk_send(1'b0, 1'b0);

        $display("D12: 40 random bytes rich in ones, ce = 1 in 8, continuous input");
        pk_begin;
        for (w = 0; w < 40; w = w + 1) begin
            rr = $random(seed);
            bv = rr[7:0] | rr[15:8];
            pk_add(bv);
        end
        pk_send(1'b0, 1'b0);
        chk_cont = 1'b0;
        ce_mode  = 0;

        // ---------------- random packets in all modes ----------------
        for (cm = 0; cm < 3; cm = cm + 1) begin
            for (rm = 0; rm < 3; rm = rm + 1) begin
                $display("R: ce_mode = %0d, ro_mode = %0d", cm, rm);
                ce_mode = cm;
                ro_mode = rm;
                for (p = 0; p < 25; p = p + 1) begin
                    nbytes = 1 + ({$random(seed)} % 20);
                    dis_r  = (({$random(seed)} % 8) == 0);
                    pk_begin;
                    for (w = 0; w < nbytes; w = w + 1) begin
                        rr = $random(seed);
                        bv = rr[7:0] | rr[15:8];                 // biased towards ones
                        if (({$random(seed)} % 6) == 0) bv = 8'hFF;
                        if (({$random(seed)} % 20) == 0) bv = 8'h00;
                        pk_add(bv);
                    end
                    pk_send(dis_r, (p % 2));
                end
            end
        end

        // ---------------- final checks ----------------
        repeat (20) @(posedge clk);
        if (pkts_checked != pkts_sent) begin
            errors = errors + 1;
            $display("ERROR: %0d packets sent, %0d checked", pkts_sent, pkts_checked);
        end
        if (out_valid !== 1'b0 || dut.acc_cnt !== 5'd0 || dut.last_pend !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not empty at the end");
        end

        $display("--------------------------------------------------");
        $display("Packets checked: %0d", pkts_checked);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    // watchdog
    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
