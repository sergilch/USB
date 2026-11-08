//-----------------------------------------------------------------------------
// tb_usb_tx_path.v - self-checking testbench for usb_tx_path
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_path usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v tb_usb_tx_path.v
//   vvp sim_path
//
// A byte source (one byte per ce60 tick at most, in_last on the last byte)
// feeds the DUT.  A line decoder rebuilds every packet from txd / tx_en /
// tx_se0 independently of the DUT: bit timing (HS 1, FS 40, LS 320 clk_bit
// cycles per bit, tx_en high for exactly n bit times), EOP (HS 8 bits at the
// inverted level, FS/LS SE0 SE0 J), NRZI decode from J, de-stuffing (a 0 must
// follow every run of six 1s, also at the end of the packet), a whole number of
// bytes, and the bytes themselves.  With bypass_en there is no NRZI and no
// stuffing.  Also checked:
//   * tx_speed of every packet;
//   * tx_underrun never pulses, except in the directed underrun case;
//   * busy: high from the first accepted byte of a packet until its tx_done,
//     high whenever tx_en is high, low at the end of every run;
//   * one tx_done per packet;
//   * underrun (HS, the source pauses inside a packet): tx_underrun pulses once,
//     the line packet is cut short (EOP still correct, the decoded bytes are a
//     prefix of the packet), the rest of that packet is discarded, and the
//     following packet is sent correctly.
// Back-to-back packets of the same configuration overlap in the pipeline (the
// next packet enters the stuffer while the serializer sends the EOP).  The
// configuration is only changed while busy = 0.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_tx_path;

    parameter real    HALF   = 1.042;     // ~480 MHz
    parameter integer FS_DIV = 40;
    parameter integer LS_DIV = 320;

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
    reg  [1:0] speed     = 2'b00;
    reg        bypass_en = 1'b0;
    reg        in_valid  = 1'b0;
    reg  [7:0] in_data   = 8'd0;
    reg        in_last   = 1'b0;
    wire       in_ready;
    wire       txd, tx_en, tx_se0, busy, tx_done, tx_underrun;
    wire [1:0] tx_speed;

    usb_tx_path #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) dut (
        .clk_bit     (clk_bit),
        .rst_n       (rst_n),
        .ce60        (ce60),
        .speed       (speed),
        .bypass_en   (bypass_en),
        .in_valid    (in_valid),
        .in_ready    (in_ready),
        .in_data     (in_data),
        .in_last     (in_last),
        .txd         (txd),
        .tx_en       (tx_en),
        .tx_se0      (tx_se0),
        .tx_speed    (tx_speed),
        .busy        (busy),
        .tx_done     (tx_done),
        .tx_underrun (tx_underrun)
    );

    integer errors = 0;
    integer seed   = 32'h7E57_0001;

    // ---------------- packet queue (source and expected line) ----------------
    reg [7:0] q_b    [0:16383];           // 256 slots x 64 bytes
    integer   q_len  [0:255];
    reg [1:0] q_spd  [0:255];
    reg       q_byp  [0:255];
    reg       q_trunc[0:255];             // underrun expected: line packet is cut short
    integer   q_gapat[0:255];             // source pauses before this byte (-1: none)
    integer   q_gaplen[0:255];
    integer   q_tail = 0;                 // packets queued
    integer   q_src  = 0;                 // packet being sent by the source
    integer   q_line = 0;                 // next packet expected on the line

    reg       allow_underrun = 1'b0;
    integer   underruns = 0;
    integer   done_cnt  = 0;
    integer   pkts_checked = 0;

    reg [7:0] src_bytes [0:63];

    // ---------------- source (acts on ce60 ticks) ----------------
    reg     src_gaps = 1'b0;              // random gaps inside packets (FS / LS only)
    integer s_idx = 0;
    integer s_gap = 0;
    integer s_pause = 0;
    integer bytes_in = 0;
    reg     s_pkt_open = 1'b0;            // first byte of the current packet accepted

    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            if (in_valid && in_ready) begin
                bytes_in = bytes_in + 1;
                s_idx    = s_idx + 1;
                if (in_last) begin
                    q_src  = q_src + 1;
                    s_idx  = 0;
                    s_gap  = {$random(seed)} % 3;
                end else if (src_gaps) begin
                    s_gap  = {$random(seed)} % 3;
                end
                in_valid <= 1'b0;
            end
            if (!(in_valid && !in_ready)) begin
                if ((q_src < q_tail) && (s_idx == q_gapat[q_src % 256]) && (s_pause < q_gaplen[q_src % 256])) begin
                    s_pause  = s_pause + 1;      // directed pause inside the packet
                    in_valid <= 1'b0;
                end else if (s_gap > 0) begin
                    s_gap    = s_gap - 1;
                    in_valid <= 1'b0;
                end else if (q_src < q_tail) begin
                    if (s_idx != q_gapat[q_src % 256]) s_pause = 0;
                    in_valid <= 1'b1;
                    in_data  <= q_b[(q_src % 256) * 64 + s_idx];
                    in_last  <= (s_idx == q_len[q_src % 256] - 1);
                end
            end
        end
    end

    // ---------------- line monitor / decoder ----------------
    reg       capturing = 1'b0;
    integer   cyc     = 0;
    integer   cap_n   = 0;
    integer   cap_div = 1;
    reg [1:0] cap_spd = 2'b00;
    integer   cur     = 0;
    reg       sym_se0 [0:2047];
    reg       sym_txd [0:2047];
    reg       dec_b   [0:2047];
    reg       ds_b    [0:2047];

    task check_packet;
        integer n, i, k, ndata, c, bn, dn, nbytes, b, j;
        reg     prev, before, mism, byp, trunc;
        reg [7:0] bv;
        begin
            n     = cap_n;
            byp   = q_byp[cur];
            trunc = q_trunc[cur];

            if (cyc != n * cap_div) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_en high for %0d cycles, expected %0d (%0d bits x %0d)",
                         $time, cyc, n * cap_div, n, cap_div);
            end

            ndata = 0;
            if (cap_spd == 2'b00) begin
                if (n < 9) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: HS packet too short (%0d bits)", $time, n);
                end else begin
                    before = sym_txd[n - 9];
                    for (k = n - 8; k < n; k = k + 1) begin
                        if (sym_se0[k] || (sym_txd[k] === before)) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: bad HS EOP bit %0d", $time, k);
                        end
                    end
                    ndata = n - 8;
                end
            end else begin
                if (n < 4) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: FS/LS packet too short (%0d bits)", $time, n);
                end else begin
                    if (!(sym_se0[n-3] && sym_se0[n-2] && !sym_se0[n-1] && (sym_txd[n-1] === 1'b1))) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: FS/LS EOP is not SE0, SE0, J", $time);
                    end
                    ndata = n - 3;
                end
            end

            // NRZI decode
            prev = 1'b1;                                   // line idles in J
            bn   = 0;
            for (i = 0; i < ndata; i = i + 1) begin
                if (sym_se0[i]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: tx_se0 inside the data at bit %0d", $time, i);
                end
                if (byp) dec_b[bn] = sym_txd[i];
                else     dec_b[bn] = (sym_txd[i] === prev);
                prev = sym_txd[i];
                bn   = bn + 1;
            end

            // de-stuff
            c  = 0;
            dn = 0;
            for (i = 0; i < bn; i = i + 1) begin
                if (byp) begin
                    ds_b[dn] = dec_b[i];
                    dn       = dn + 1;
                end else if (c == 6) begin
                    if (dec_b[i] !== 1'b0) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: stuffed 0 missing at decoded bit %0d", $time, i);
                    end
                    c = 0;
                end else begin
                    ds_b[dn] = dec_b[i];
                    dn       = dn + 1;
                    if (dec_b[i]) c = c + 1;
                    else          c = 0;
                end
            end
            if (!byp && !trunc && (c == 6)) begin
                errors = errors + 1;
                $display("ERROR @%0t: trailing stuff bit missing after six final ones", $time);
            end

            nbytes = dn / 8;
            if (!trunc) begin
                if ((dn % 8) != 0) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: decoded %0d bits, not a whole number of bytes", $time, dn);
                end
                if (nbytes != q_len[cur]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: decoded %0d bytes, expected %0d", $time, nbytes, q_len[cur]);
                end
            end else if (nbytes >= q_len[cur]) begin
                errors = errors + 1;
                $display("ERROR @%0t: underrun packet not cut short (%0d of %0d bytes)",
                         $time, nbytes, q_len[cur]);
            end
            mism = 1'b0;
            for (b = 0; b < nbytes && b < q_len[cur]; b = b + 1) begin
                for (j = 0; j < 8; j = j + 1) bv[j] = ds_b[b * 8 + j];
                if (!mism && (bv !== q_b[cur * 64 + b])) begin
                    mism   = 1'b1;
                    errors = errors + 1;
                    $display("ERROR @%0t: packet %0d byte %0d decoded as %02h, expected %02h",
                             $time, q_line, b, bv, q_b[cur * 64 + b]);
                end
            end
        end
    endtask

    reg     busy_seen  = 1'b0;
    integer pend       = 0;               // packets with a byte accepted and no tx_done yet
    reg     mon_in_pkt = 1'b0;

    always @(posedge clk_bit) begin
        if (rst_n) begin
            if (tx_se0 && !tx_en) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_se0 while tx_en = 0", $time);
            end
            if (tx_en && !busy) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_en high while busy = 0", $time);
            end
            // busy must cover every packet from its first byte to its tx_done
            if (tx_done) pend = pend - 1;
            if ((pend > 0) && !busy) begin
                errors = errors + 1;
                $display("ERROR @%0t: busy low with %0d packet(s) in flight", $time, pend);
            end
            if (ce60 && in_valid && in_ready) begin
                busy_seen = 1'b1;
                if (!mon_in_pkt) pend = pend + 1;
                mon_in_pkt = !in_last;
            end
            if (tx_underrun) begin
                underruns = underruns + 1;
                if (!allow_underrun) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: tx_underrun", $time);
                end
            end
            if (tx_done) done_cnt = done_cnt + 1;

            if (tx_en) begin
                if (!capturing) begin
                    capturing = 1'b1;
                    cyc       = 0;
                    cap_n     = 0;
                    cur       = q_line % 256;
                    if (q_line >= q_tail) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet on the line, but none expected", $time);
                        cap_spd = tx_speed;
                    end else begin
                        cap_spd = q_spd[cur];
                        if (tx_speed !== cap_spd) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: tx_speed = %b, expected %b", $time, tx_speed, cap_spd);
                        end
                    end
                    cap_div = (cap_spd == 2'b00) ? 1 : ((cap_spd == 2'b10) ? LS_DIV : FS_DIV);
                end
                if (((cyc % cap_div) == (cap_div / 2)) && (cap_n < 2048)) begin
                    sym_se0[cap_n] = tx_se0;
                    sym_txd[cap_n] = txd;
                    cap_n          = cap_n + 1;
                end
                cyc = cyc + 1;
            end else if (capturing) begin
                capturing = 1'b0;
                if (q_line < q_tail) begin
                    check_packet;
                    q_line = q_line + 1;
                end
                pkts_checked = pkts_checked + 1;
            end
        end
    end

    // ---------------- stimulus helpers ----------------
    task queue_packet(input integer nb, input integer gapat, input integer gaplen, input trunc);
        integer i, qi;
        begin
            qi = q_tail % 256;
            for (i = 0; i < nb; i = i + 1) q_b[qi * 64 + i] = src_bytes[i];
            q_len[qi]    = nb;
            q_spd[qi]    = speed;
            q_byp[qi]    = bypass_en;
            q_trunc[qi]  = trunc;
            q_gapat[qi]  = gapat;
            q_gaplen[qi] = gaplen;
            q_tail = q_tail + 1;
        end
    endtask

    task finish_all;
        begin
            while (!((q_src == q_tail) && (pkts_checked == q_tail) && !busy && !in_valid))
                @(posedge clk_bit);
            repeat (40) @(posedge clk_bit);
            if (busy) begin
                errors = errors + 1;
                $display("ERROR @%0t: busy still high after the run", $time);
            end
            if (done_cnt != pkts_checked) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0d tx_done pulses for %0d packets", $time, done_cnt, pkts_checked);
            end
        end
    endtask

    task set_cfg(input [1:0] spd, input byp);
        begin
            finish_all;                              // config changes only while idle
            @(negedge clk_bit);
            speed     = spd;
            bypass_en = byp;
        end
    endtask

    task fill(input integer n);
        integer i;
        reg [31:0] r;
        begin
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                case (r[10:8])
                    3'd0:    src_bytes[i] = 8'hFF;   // long runs of ones
                    3'd1:    src_bytes[i] = 8'h00;
                    3'd2:    src_bytes[i] = 8'h7F;
                    default: src_bytes[i] = r[7:0];
                endcase
            end
        end
    endtask

    task directed;
        integer w;
        begin
            src_bytes[0] = 8'hD2;                    // single byte (ACK PID)
            queue_packet(1, -1, 0, 1'b0);
            for (w = 0; w < 12; w = w + 1) src_bytes[w] = 8'hFF;
            queue_packet(12, -1, 0, 1'b0);           // all ones: a stuff bit every 6 bits
            src_bytes[0] = 8'h80; src_bytes[1] = 8'hC3; src_bytes[2] = 8'hFC;
            queue_packet(3, -1, 0, 1'b0);            // six ones at the very end
            src_bytes[0] = 8'h80; src_bytes[1] = 8'h3F;
            queue_packet(2, -1, 0, 1'b0);            // six ones ending exactly at a byte boundary
            src_bytes[0] = 8'h00; src_bytes[1] = 8'h00; src_bytes[2] = 8'h00; src_bytes[3] = 8'h80;
            src_bytes[4] = 8'h69; src_bytes[5] = 8'h55; src_bytes[6] = 8'hAA;
            queue_packet(7, -1, 0, 1'b0);            // HS SYNC + IN PID + data
        end
    endtask

    task random_run(input integer npk, input integer maxlen);
        integer i, nb;
        begin
            for (i = 0; i < npk; i = i + 1) begin
                nb = 1 + ({$random(seed)} % maxlen);
                fill(nb);
                queue_packet(nb, -1, 0, 1'b0);
            end
        end
    endtask

    // ---------------- stimulus ----------------
    initial begin
        $dumpfile("tb_usb_tx_path.vcd");
        $dumpvars(0, tb_usb_tx_path);

        rst_n = 1'b0;
        repeat (5) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (10) @(posedge clk_bit);

        $display("HS directed");
        set_cfg(2'b00, 1'b0);
        directed;
        $display("HS random, back-to-back");
        random_run(150, 40);

        $display("HS bypass (no stuffing / NRZI)");
        set_cfg(2'b00, 1'b1);
        directed;
        random_run(30, 20);

        $display("FS directed + random, gaps inside packets");
        set_cfg(2'b01, 1'b0);
        src_gaps = 1'b1;
        directed;
        random_run(25, 12);

        $display("XcvrSelect 11 (FS rate)");
        set_cfg(2'b11, 1'b0);
        random_run(3, 6);

        $display("FS bypass");
        set_cfg(2'b01, 1'b1);
        random_run(4, 6);

        $display("LS directed + random");
        set_cfg(2'b10, 1'b0);
        directed;
        random_run(4, 4);

        $display("HS underrun: source pauses inside a packet");
        set_cfg(2'b00, 1'b0);
        src_gaps = 1'b0;
        finish_all;
        allow_underrun = 1'b1;
        fill(24);
        queue_packet(24, 8, 10, 1'b1);           // 10-tick pause before byte 8
        fill(16);
        queue_packet(16, -1, 0, 1'b0);           // must come out intact
        fill(5);
        queue_packet(5, -1, 0, 1'b0);
        finish_all;
        allow_underrun = 1'b0;
        if (underruns != 1) begin
            errors = errors + 1;
            $display("ERROR: %0d tx_underrun pulses in the underrun case, expected 1", underruns);
        end

        $display("HS after underrun");
        random_run(20, 30);
        finish_all;

        repeat (20) @(posedge clk_bit);
        if (pkts_checked != q_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d packets queued, %0d seen on the line", q_tail, pkts_checked);
        end
        if (!busy_seen) begin
            errors = errors + 1;
            $display("ERROR: no byte was ever accepted");
        end
        $display("%0d packets, %0d bytes checked", pkts_checked, bytes_in);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
