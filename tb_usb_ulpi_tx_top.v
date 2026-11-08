//-----------------------------------------------------------------------------
// tb_usb_ulpi_tx_top.v - end-to-end testbench for usb_ulpi_tx_top
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_top usb_ulpi_input_capture.v usb_ulpi_bus_owner.v \
//            usb_tx_holding.v usb_tx_sync_mux.v usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_tx_datapath.v usb_ulpi_tx_top.v \
//            tb_usb_ulpi_tx_top.v
//   vvp sim_top
//
// Pin level, like a real ULPI system:
//   * a ULPI Link TX model (clocked on ce60 ticks) drives DATA / STP: TXCMD held until
//     NXT, one byte per NXT, STP in the tick after the last byte.  It releases the bus
//     when it sees DIR = 1 and repeats a TXCMD that was not acknowledged yet (the PHY
//     wins a collision); it flags an error if DIR rises inside a packet;
//   * a PHY burst source (arb_*) stands in for RX data / RXCMD / register read data and
//     competes for the bus; the Link-side monitor checks every burst byte and its NXT
//     marker on the pins;
//   * a line decoder rebuilds the bytes from txd / tx_en / tx_se0 independently of the
//     DUT: gapless timing, EOP (HS 8 inverted bits, FS/LS SE0 SE0 J), NRZI decode,
//     de-stuffing and then SYNC (HS 00 00 00 80, FS/LS 80) + PID byte {~pid, pid}
//     (not for NOPID) + payload.  bypass_en / sync_dis variants are covered.
// tx_underrun must never pulse.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_tx_top;

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
    reg  [7:0] lk_data    = 8'd0;          // Link-driven pins
    reg        lk_stp     = 1'b0;
    wire       ulpi_dir, ulpi_nxt, ulpi_data_oe;
    wire [7:0] ulpi_data_out;

    reg  [1:0] speed      = 2'b00;
    reg        bypass_en  = 1'b0;
    reg        sync_dis   = 1'b0;

    reg        arb_valid   = 1'b0;
    reg  [7:0] arb_data    = 8'd0;
    reg        arb_is_data = 1'b0;
    wire       arb_ready;

    wire       lnk_valid, lnk_stp_o, nxt_seen, cmd_regw, cmd_regr, cmd_ext;
    wire [7:0] lnk_data_o;
    wire [5:0] cmd_addr;
    wire       txd, tx_en, tx_se0;
    wire [1:0] tx_speed;
    wire       busy, tx_done, tx_underrun;

    usb_ulpi_tx_top #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) dut (
        .clk_bit       (clk_bit),
        .rst_n         (rst_n),
        .ce60          (ce60),
        .ulpi_data_in  (lk_data),
        .ulpi_stp      (lk_stp),
        .ulpi_dir      (ulpi_dir),
        .ulpi_nxt      (ulpi_nxt),
        .ulpi_data_out (ulpi_data_out),
        .ulpi_data_oe  (ulpi_data_oe),
        .speed         (speed),
        .bypass_en     (bypass_en),
        .sync_dis      (sync_dis),
        .arb_valid     (arb_valid),
        .arb_data      (arb_data),
        .arb_is_data   (arb_is_data),
        .arb_ready     (arb_ready),
        .dir_hold      (1'b0),
        .reg_nxt_n     (1'b0),
        .lnk_valid     (lnk_valid),
        .lnk_data      (lnk_data_o),
        .lnk_stp       (lnk_stp_o),
        .nxt_seen      (nxt_seen),
        .cmd_regw      (cmd_regw),
        .cmd_regr      (cmd_regr),
        .cmd_ext       (cmd_ext),
        .cmd_addr      (cmd_addr),
        .txd           (txd),
        .tx_en         (tx_en),
        .tx_se0        (tx_se0),
        .tx_speed      (tx_speed),
        .busy          (busy),
        .tx_done       (tx_done),
        .tx_underrun   (tx_underrun)
    );

    integer errors = 0;
    integer seed    = 32'h6B6B_6B6B;
    integer seed_lk = 32'h1C1C_1C1C;
    integer seed_rx = 32'h2D2D_2D2D;

    // ---------------- expected line packets ----------------
    reg [7:0] q_exp [0:12287];            // 128 slots x 96 bytes
    integer   q_len [0:127];
    reg [1:0] q_spd [0:127];
    reg       q_byp [0:127];
    integer   q_head = 0;
    integer   q_tail = 0;
    integer   pkts_checked = 0;
    integer   done_cnt     = 0;

    reg [7:0] src_bytes [0:63];

    // ---------------- ULPI Link TX model (acts on ce60 ticks) ----------------
    reg [3:0] lk_pid [0:127];
    reg       lk_nop [0:127];
    integer   lk_n   [0:127];
    reg [7:0] lk_pay [0:8191];
    integer   lk_head = 0;                // packet being sent
    integer   lk_tail = 0;                // packets queued
    integer   lk_state = 0;               // 0 idle, 1 TXCMD, 2 data, 3 STP
    integer   lk_idx   = 0;
    integer   lk_gap   = 0;
    integer   lk_retries = 0;
    reg       link_gaps  = 1'b1;
    integer   h;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            lk_data <= 8'd0;
            lk_stp  <= 1'b0;
        end else if (ce60) begin
            h = lk_head % 128;
            if (ulpi_dir) begin
                if ((lk_state == 2) || (lk_state == 3)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose inside a TX packet", $time);
                end
                lk_data <= 8'd0;
                lk_stp  <= 1'b0;
                if (lk_state == 1) begin           // TXCMD not acknowledged: PHY won, retry later
                    lk_state   = 0;
                    lk_retries = lk_retries + 1;
                    lk_gap     = 0;
                end
            end else begin
                case (lk_state)
                    0: begin
                        lk_data <= 8'd0;
                        lk_stp  <= 1'b0;
                        if (lk_gap > 0) begin
                            lk_gap = lk_gap - 1;
                        end else if (lk_head != lk_tail) begin
                            lk_data  <= lk_nop[h] ? 8'h40 : {4'h4, lk_pid[h]};
                            lk_state = 1;
                        end
                    end
                    1: begin
                        if (ulpi_nxt) begin
                            if (lk_n[h] > 0) begin
                                lk_idx   = 0;
                                lk_data <= lk_pay[h * 64];
                                lk_state = 2;
                            end else begin
                                lk_data <= 8'd0;
                                lk_stp  <= 1'b1;
                                lk_state = 3;
                            end
                        end
                    end
                    2: begin
                        if (ulpi_nxt) begin
                            lk_idx = lk_idx + 1;
                            if (lk_idx == lk_n[h]) begin
                                lk_data <= 8'd0;
                                lk_stp  <= 1'b1;
                                lk_state = 3;
                            end else begin
                                lk_data <= lk_pay[h * 64 + lk_idx];
                            end
                        end
                    end
                    default: begin                  // STP tick
                        lk_stp  <= 1'b0;
                        lk_data <= 8'd0;
                        lk_head  = lk_head + 1;
                        lk_state = 0;
                        lk_gap   = link_gaps ? ({$random(seed_lk)} % 5) : 0;
                    end
                endcase
            end
        end
    end

    // ---------------- PHY burst source (arb_*) ----------------
    reg [7:0] rb_b   [0:4095];            // 256 bursts x 16 bytes
    reg       rb_d   [0:4095];
    integer   rb_len [0:255];
    integer   rb_i = 0;                   // burst being sent
    integer   rb_k = 0;
    integer   rb_n = 0;                   // bursts queued
    integer   rgap = 0;
    reg       rx_gaps = 1'b1;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            arb_valid   <= 1'b0;
            arb_data    <= 8'd0;
            arb_is_data <= 1'b0;
        end else if (ce60) begin
            if (arb_valid && arb_ready) begin               // pre-edge values
                if (rb_k + 1 == rb_len[rb_i]) begin
                    rb_i = rb_i + 1;
                    rb_k = 0;
                    rgap = rx_gaps ? ({$random(seed_rx)} % 41) : 0;
                end else begin
                    rb_k = rb_k + 1;
                end
            end else if (!arb_valid && (rgap > 0)) begin
                rgap = rgap - 1;
            end
            if ((rb_i < rb_n) && (rgap == 0)) begin
                arb_valid   <= 1'b1;
                arb_data    <= rb_b[rb_i * 16 + rb_k];
                arb_is_data <= rb_d[rb_i * 16 + rb_k];
            end else begin
                arb_valid   <= 1'b0;
            end
        end
    end

    task queue_burst(input integer n);
        integer i;
        reg [31:0] r;
        begin
            rb_len[rb_n] = n;
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                rb_b[rb_n * 16 + i] = r[7:0];
                rb_d[rb_n * 16 + i] = r[8];
            end
            rb_n = rb_n + 1;
        end
    endtask

    // Link-side view of the PHY bursts
    integer rx_i = 0;
    integer rx_k = 0;
    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            if (ulpi_data_oe && !ulpi_dir) begin
                errors = errors + 1;
                $display("ERROR @%0t: ulpi_data_oe without DIR", $time);
            end
            if (ulpi_dir && !ulpi_data_oe && ulpi_nxt) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT high in an undriven DIR tick", $time);
            end
            if (ulpi_data_oe) begin
                if (rx_i >= rb_n) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: unexpected PHY byte %02h", $time, ulpi_data_out);
                end else begin
                    if (ulpi_data_out !== rb_b[rx_i * 16 + rx_k]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: PHY byte = %02h, expected %02h", $time, ulpi_data_out, rb_b[rx_i * 16 + rx_k]);
                    end
                    if (ulpi_nxt !== rb_d[rx_i * 16 + rx_k]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: NXT = %b with PHY byte, expected %b", $time, ulpi_nxt, rb_d[rx_i * 16 + rx_k]);
                    end
                    rx_k = rx_k + 1;
                    if (rx_k == rb_len[rx_i]) begin
                        rx_i = rx_i + 1;
                        rx_k = 0;
                    end
                end
            end
        end
    end

    // ---------------- line monitor / decoder ----------------
    reg       capturing = 1'b0;
    integer   cyc       = 0;
    integer   cap_n     = 0;
    integer   cap_div   = 1;
    reg [1:0] cap_spd   = 2'b00;
    integer   cur_qi    = 0;
    reg       sym_se0 [0:1023];
    reg       sym_txd [0:1023];
    reg       dec_b   [0:1023];
    reg       ds_b    [0:1023];

    task check_packet;
        integer n, i, k, ndata, c, bn, dn, nbytes, b, j;
        reg     prev, before, mism;
        reg [7:0] bv;
        begin
            n = cap_n;

            if (cyc != n * cap_div) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_en high for %0d cycles, expected %0d (%0d symbols x %0d)",
                         $time, cyc, n * cap_div, n, cap_div);
            end

            ndata = 0;
            if (cap_spd == 2'b00) begin
                if (n < 9) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: HS packet too short (%0d symbols)", $time, n);
                end else begin
                    before = sym_txd[n - 9];
                    for (k = n - 8; k < n; k = k + 1) begin
                        if (sym_se0[k] || (sym_txd[k] === before)) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: bad HS EOP symbol %0d", $time, k);
                        end
                    end
                    ndata = n - 8;
                end
            end else begin
                if (n < 4) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: FS/LS packet too short (%0d symbols)", $time, n);
                end else begin
                    if (!(sym_se0[n-3] && sym_se0[n-2] && !sym_se0[n-1] && (sym_txd[n-1] === 1'b1))) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: FS/LS EOP is not SE0, SE0, J", $time);
                    end
                    ndata = n - 3;
                end
            end

            prev = 1'b1;                                   // line idles in J
            bn   = 0;
            for (i = 0; i < ndata; i = i + 1) begin
                if (sym_se0[i]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: tx_se0 set inside the data at symbol %0d", $time, i);
                end
                if (q_byp[cur_qi]) dec_b[bn] = sym_txd[i];
                else               dec_b[bn] = (sym_txd[i] === prev);
                prev = sym_txd[i];
                bn   = bn + 1;
            end

            c  = 0;
            dn = 0;
            for (i = 0; i < bn; i = i + 1) begin
                if (q_byp[cur_qi]) begin
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
            if (!q_byp[cur_qi] && (c == 6)) begin
                errors = errors + 1;
                $display("ERROR @%0t: trailing stuff bit missing after six final ones", $time);
            end

            if ((dn % 8) != 0) begin
                errors = errors + 1;
                $display("ERROR @%0t: decoded %0d bits, not a whole number of bytes", $time, dn);
            end
            nbytes = dn / 8;
            if (nbytes != q_len[cur_qi]) begin
                errors = errors + 1;
                $display("ERROR @%0t: decoded %0d bytes, expected %0d", $time, nbytes, q_len[cur_qi]);
            end else begin
                mism = 1'b0;
                for (b = 0; b < nbytes; b = b + 1) begin
                    for (j = 0; j < 8; j = j + 1) bv[j] = ds_b[b * 8 + j];
                    if (!mism && (bv !== q_exp[cur_qi * 96 + b])) begin
                        mism   = 1'b1;
                        errors = errors + 1;
                        $display("ERROR @%0t: byte %0d decoded as %02h, expected %02h",
                                 $time, b, bv, q_exp[cur_qi * 96 + b]);
                    end
                end
            end
        end
    endtask

    always @(posedge clk_bit) begin
        if (rst_n) begin
            if (tx_se0 && !tx_en) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_se0 set while tx_en = 0", $time);
            end
            if (tx_underrun) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_underrun", $time);
            end
            if (tx_done) done_cnt = done_cnt + 1;

            if (tx_en) begin
                if (!capturing) begin
                    capturing = 1'b1;
                    cyc       = 0;
                    cap_n     = 0;
                    if (q_head == q_tail) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet on the line, but none expected", $time);
                        cap_spd = tx_speed;
                    end else begin
                        cur_qi  = q_head % 128;
                        cap_spd = q_spd[cur_qi];
                        if (tx_speed !== cap_spd) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: tx_speed = %b, expected %b", $time, tx_speed, cap_spd);
                        end
                    end
                    cap_div = (cap_spd == 2'b00) ? 1 : ((cap_spd == 2'b10) ? LS_DIV : FS_DIV);
                end
                if (((cyc % cap_div) == (cap_div / 2)) && (cap_n < 1024)) begin
                    sym_se0[cap_n] = tx_se0;
                    sym_txd[cap_n] = txd;
                    cap_n          = cap_n + 1;
                end
                cyc = cyc + 1;
            end else if (capturing) begin
                capturing = 1'b0;
                if (q_head != q_tail) begin
                    check_packet;
                    q_head = q_head + 1;
                end
                pkts_checked = pkts_checked + 1;
            end
        end
    end

    // ---------------- stimulus helpers ----------------
    task queue_packet(input [3:0] pid, input nopid, input integer nb);
        integer i, k, qi, lh;
        begin
            // Link side
            lh = lk_tail % 128;
            lk_pid[lh] = pid;
            lk_nop[lh] = nopid;
            lk_n[lh]   = nb;
            for (i = 0; i < nb; i = i + 1) lk_pay[lh * 64 + i] = src_bytes[i];
            lk_tail = lk_tail + 1;

            // expected byte stream on the line
            qi = q_tail % 128;
            k  = 0;
            if (!sync_dis) begin
                if (speed == 2'b00) begin
                    q_exp[qi * 96 + 0] = 8'h00;
                    q_exp[qi * 96 + 1] = 8'h00;
                    q_exp[qi * 96 + 2] = 8'h00;
                    q_exp[qi * 96 + 3] = 8'h80;
                    k = 4;
                end else begin
                    q_exp[qi * 96 + 0] = 8'h80;
                    k = 1;
                end
            end
            if (!nopid) begin
                q_exp[qi * 96 + k] = {~pid, pid};
                k = k + 1;
            end
            for (i = 0; i < nb; i = i + 1) begin
                q_exp[qi * 96 + k] = src_bytes[i];
                k = k + 1;
            end
            if (k != 0) begin                  // k == 0: nothing is sent on the line
                q_len[qi] = k;
                q_spd[qi] = speed;
                q_byp[qi] = bypass_en;
                q_tail    = q_tail + 1;
            end
        end
    endtask

    task finish_all;
        begin
            while (!((lk_head == lk_tail) && (lk_state == 0) && (rb_i == rb_n) && (rx_i == rb_n)
                     && (pkts_checked == q_tail))) @(posedge clk_bit);
            repeat (40) @(posedge clk_bit);
        end
    endtask

    task set_cfg(input [1:0] spd, input byp, input sdis);
        begin
            @(negedge clk_bit);
            speed     = spd;
            bypass_en = byp;
            sync_dis  = sdis;
        end
    endtask

    task fill(input integer n);
        integer i;
        reg [31:0] r;
        begin
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                src_bytes[i] = r[7:0] | r[15:8];
            end
        end
    endtask

    task rand_burst;
        begin
            queue_burst(1 + ({$random(seed)} % 8));
        end
    endtask

    // directed packets in the current configuration
    task directed(input integer all);
        integer w;
        begin
            queue_packet(4'h2, 1'b0, 0);                         // ACK
            src_bytes[0] = 8'h00; src_bytes[1] = 8'h10;          // SETUP token
            queue_packet(4'hD, 1'b0, 2);
            src_bytes[0] = 8'h34; src_bytes[1] = 8'h12;          // SOF
            queue_packet(4'h5, 1'b0, 2);
            queue_packet(4'h0, 1'b1, 0);                         // NOPID, nothing else
            if (all != 0) begin
                for (w = 0; w < 10; w = w + 1) src_bytes[w] = 8'hFF;   // DATA0, all ones
                queue_packet(4'h3, 1'b0, 10);
                src_bytes[0] = 8'hFC;                                    // six ones at the end
                queue_packet(4'hB, 1'b0, 1);
                src_bytes[0] = 8'h2D; src_bytes[1] = 8'h00; src_bytes[2] = 8'h10;
                queue_packet(4'h0, 1'b1, 3);                             // NOPID: PID from the Link
            end
            finish_all;
        end
    endtask

    // ---------------- stimulus ----------------
    integer g, p, nb;
    reg [31:0] rr;
    reg [3:0]  rpid;
    reg        rnop;

    initial begin
        $dumpfile("tb_usb_ulpi_tx_top.vcd");
        $dumpvars(0, tb_usb_ulpi_tx_top);

        rst_n = 1'b0;
        repeat (5) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (10) @(posedge clk_bit);

        $display("Directed TX, HS");
        set_cfg(2'b00, 1'b0, 1'b0);
        directed(1);

        $display("Directed TX, FS");
        set_cfg(2'b01, 1'b0, 1'b0);
        directed(1);

        $display("Directed TX, LS (short set)");
        set_cfg(2'b10, 1'b0, 1'b0);
        directed(0);

        $display("Directed TX, HS, SYNC suppressed");
        set_cfg(2'b00, 1'b0, 1'b1);
        directed(1);

        $display("HS, no stuffing / NRZI / SYNC (chirp-like raw patterns)");
        set_cfg(2'b00, 1'b1, 1'b1);
        src_bytes[0] = 8'h00; src_bytes[1] = 8'h00; src_bytes[2] = 8'h00;
        queue_packet(4'h0, 1'b1, 3);
        src_bytes[0] = 8'hFF; src_bytes[1] = 8'hAA; src_bytes[2] = 8'h55; src_bytes[3] = 8'hFF;
        queue_packet(4'h0, 1'b1, 4);
        queue_packet(4'h0, 1'b1, 0);                             // nothing to send at all
        finish_all;

        $display("PHY bursts only");
        set_cfg(2'b00, 1'b0, 1'b0);
        for (p = 0; p < 12; p = p + 1) rand_burst;
        finish_all;

        $display("Mixed HS: TX packets and PHY bursts compete for the bus");
        for (g = 0; g < 8; g = g + 1) begin
            set_cfg(2'b00, 1'b0, 1'b0);
            link_gaps = (g % 2);
            rx_gaps   = (g % 3) != 0;
            for (p = 0; p < 6; p = p + 1) begin
                rr   = $random(seed);
                rnop = (rr[3:0] == 4'd0);
                rpid = (rr[7:4] == 4'd0) ? 4'd1 : rr[7:4];
                nb   = {$random(seed)} % 31;
                fill(nb);
                queue_packet(rpid, rnop, nb);
                rand_burst;
            end
            finish_all;
        end

        $display("Mixed FS");
        for (g = 0; g < 3; g = g + 1) begin
            set_cfg(2'b01, 1'b0, 1'b0);
            link_gaps = 1'b1;
            rx_gaps   = 1'b1;
            for (p = 0; p < 3; p = p + 1) begin
                rr   = $random(seed);
                rpid = (rr[7:4] == 4'd0) ? 4'd1 : rr[7:4];
                nb   = {$random(seed)} % 9;
                fill(nb);
                queue_packet(rpid, 1'b0, nb);
                rand_burst;
            end
            finish_all;
        end

        $display("Mixed LS");
        set_cfg(2'b10, 1'b0, 1'b0);
        for (p = 0; p < 2; p = p + 1) begin
            nb = {$random(seed)} % 4;
            fill(nb);
            queue_packet(4'h3, 1'b0, nb);
            rand_burst;
        end
        finish_all;

        // ---------------- final checks ----------------
        repeat (20) @(posedge clk_bit);
        if (pkts_checked != q_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d packets expected on the line, %0d seen", q_tail, pkts_checked);
        end
        if (done_cnt != q_tail) begin
            errors = errors + 1;
            $display("ERROR: tx_done pulses = %0d, packets = %0d", done_cnt, q_tail);
        end
        if (rx_i != rb_n) begin
            errors = errors + 1;
            $display("ERROR: %0d PHY bursts queued, %0d completed", rb_n, rx_i);
        end
        if (busy !== 1'b0 || tx_en !== 1'b0 || ulpi_dir !== 1'b0 || ulpi_nxt !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not idle at the end");
        end

        $display("--------------------------------------------------");
        $display("TX packets decoded: %0d, PHY bursts delivered: %0d, TXCMD retries after losing the bus: %0d",
                 pkts_checked, rx_i, lk_retries);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
