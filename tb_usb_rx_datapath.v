//-----------------------------------------------------------------------------
// tb_usb_rx_datapath.v - top-level (loopback) testbench for the RX datapath
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxdp usb_bit_stuffer.v usb_nrzi_encoder.v \
//            usb_tx_serializer.v usb_tx_path.v usb_rx_nrzi_decoder.v \
//            usb_rx_sync_detect.v usb_rx_bit_unstuffer.v usb_rx_deserializer.v \
//            usb_rx_eop_check.v usb_rx_decoder.v usb_rx_elastic_buffer.v \
//            usb_rx_hs_frontend.v usb_rx_fsls_frontend.v usb_rx_datapath.v \
//            usb_ulpi_rx_handler.v tb_usb_rx_datapath.v
//   vvp sim_rxdp
//
// Set-up
//   * Far end: a usb_tx_path ("the host") on its own 480 MHz clock clk_far with
//     a ppm offset against the local clk_bit, fed with SYNC + PID + payload.
//     A raw symbol generator on the same clock can replace it to send
//     hand-made line patterns (protocol errors, keep-alive).
//   * Line / AFE model
//       HS   : ideal CDR - clk_rx = inverted clk_far (samples mid-bit),
//              hs_rxd = line level; squelch deasserts and the CDR locks a random
//              number of bits after the packet starts (2..20 SYNC bits lost),
//              squelch asserts a few bits after the EOP; random noise on hs_rxd
//              while the line is idle.
//       FS/LS: D+ / D- (LS polarity inverted) with random D+/D- skew (SE0 / SE1
//              glitches at every crossover); rxrcv switches half-way.
//   * DUT: usb_rx_datapath.  Its output also drives a usb_ulpi_rx_handler
//     (RXCMD model: every RxActive / RxError change is "sent" at once).
//
// Checked
//   * every received packet against the packet sent: rx_start, the bytes after
//     SYNC (PID + payload), rx_end, rx_error = 0;
//   * error packets (bit-stuff violation, EOP not on a byte boundary, squelch
//     in the middle of a packet): rx_end with rx_error; all bytes but the last
//     one received are a prefix of the packet (at most one extra byte);
//   * packets that must not be received (LS keep-alive, packets during the
//     local transmitter's hold-off) do not appear;
//   * framing: one event per tick, no bytes / end outside a packet, no start
//     inside a packet;
//   * the RX Data Handler forwards exactly the bytes of the datapath and never
//     reports an overrun;
//   * HS at 0 / +1000 / -1000 ppm incl. 1027-byte packets, FS at 0 / +-2500 ppm,
//     LS at +-15000 ppm, XcvrSelect 11.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_datapath;

    parameter real    HALF    = 1.0416667;     // 480 MHz
    parameter integer FS_DIV  = 40;
    parameter integer LS_DIV  = 320;
    parameter integer HOLDOFF = 64;

    // ---------------- clocks ----------------
    reg  clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;

    real far_half = 1.0416667;
    reg  clk_far  = 1'b0;
    initial begin
        #0.37;                                   // arbitrary phase
        forever #(far_half) clk_far = ~clk_far;
    end

    reg rst_n;

    reg [2:0] ce_cnt;
    wire      ce60 = (ce_cnt == 3'd7);
    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) ce_cnt <= 3'd0;
        else        ce_cnt <= ce_cnt + 3'd1;
    end

    reg [2:0] fce_cnt = 3'd0;
    wire      ce60_far = (fce_cnt == 3'd7);
    always @(posedge clk_far) fce_cnt <= fce_cnt + 3'd1;

    integer errors = 0;
    integer seed   = 32'h0BAD_F00D;

    // ---------------- configuration ----------------
    reg [1:0] speed  = 2'b00;
    reg       loc_tx = 1'b0;                     // local transmitter active
    reg       rx_en  = 1'b1;

    // ---------------- far transmitter ----------------
    reg  [7:0] f_b [0:2047];
    integer    f_n = 0, f_idx = 0;
    reg        f_go = 1'b0;
    reg        f_valid = 1'b0;
    reg  [7:0] f_data  = 8'd0;
    reg        f_last  = 1'b0;
    wire       f_ready, f_txd, f_tx_en, f_tx_se0, f_busy, f_done, f_under;
    wire [1:0] f_tx_speed;

    usb_tx_path #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) u_far (
        .clk_bit     (clk_far),
        .rst_n       (rst_n),
        .ce60        (ce60_far),
        .speed       (speed),
        .bypass_en   (1'b0), .eop_dis(1'b0),
        .in_valid    (f_valid),
        .in_ready    (f_ready),
        .in_data     (f_data),
        .in_last     (f_last),
        .txd         (f_txd),
        .tx_en       (f_tx_en),
        .tx_se0      (f_tx_se0),
        .tx_speed    (f_tx_speed),
        .busy        (f_busy),
        .tx_done     (f_done),
        .tx_underrun (f_under)
    );

    always @(posedge clk_far) begin
        if (rst_n && ce60_far) begin
            if (f_valid && f_ready) begin
                f_idx = f_idx + 1;
                if (f_last) f_go = 1'b0;
            end
            if (f_go && f_idx < f_n) begin
                f_valid <= 1'b1;
                f_data  <= f_b[f_idx];
                f_last  <= (f_idx == f_n - 1);
            end else begin
                f_valid <= 1'b0;
            end
        end
        if (f_under) begin
            errors = errors + 1;
            $display("ERROR @%0t: far transmitter underrun (testbench)", $time);
        end
    end

    // ---------------- raw symbol generator (0 = K, 1 = J, 2 = SE0) ----------------
    reg [1:0] r_sym [0:16383];
    integer   r_n = 0, r_i = 0, r_cnt = 0;
    reg       r_go = 1'b0;
    reg       r_en = 1'b0, r_txd = 1'b1, r_se0 = 1'b0;
    integer   bit_div = 1;

    always @(posedge clk_far) begin
        if (r_go) begin
            if (r_cnt == 0) begin
                if (r_i >= r_n) begin
                    r_en  <= 1'b0;
                    r_txd <= 1'b1;
                    r_se0 <= 1'b0;
                    r_go  = 1'b0;
                end else begin
                    r_en  <= 1'b1;
                    r_txd <= (r_sym[r_i] == 2'd1);
                    r_se0 <= (r_sym[r_i] == 2'd2);
                    r_i   = r_i + 1;
                    r_cnt = bit_div - 1;
                end
            end else begin
                r_cnt = r_cnt - 1;
            end
        end
    end

    reg  raw_mode = 1'b0;
    wire l_en  = raw_mode ? r_en  : f_tx_en;
    wire l_txd = raw_mode ? r_txd : f_txd;
    wire l_se0 = raw_mode ? r_se0 : f_tx_se0;

    // ---------------- HS line / CDR model (clk_far) ----------------
    wire    clk_rx = ~clk_far;
    reg     hs_rxd = 1'b1;
    reg     hs_sq  = 1'b1;
    reg     hs_lk  = 1'b0;
    reg     sq_force = 1'b0;                      // squelch forced on (error test)
    integer sq_on = 4, lk_on = 4, sq_off = 4;    // bits
    integer on_cnt = 0, off_cnt = 0;
    reg     l_en_q = 1'b0;

    always @(posedge clk_far) begin
        l_en_q <= l_en;
        hs_rxd <= #0.1 (l_en ? l_txd : $random(seed));
        if (l_en) begin
            off_cnt = 0;
            if (!l_en_q) on_cnt = 0;
            else         on_cnt = on_cnt + 1;
            if (on_cnt >= sq_on)          hs_sq <= sq_force;
            if (on_cnt >= sq_on + lk_on)  hs_lk <= 1'b1;
            if (sq_force)                 hs_sq <= 1'b1;
        end else begin
            off_cnt = off_cnt + 1;
            if (off_cnt >= sq_off) begin
                hs_sq <= 1'b1;
                hs_lk <= 1'b0;
            end
        end
    end

    // ---------------- FS / LS line model ----------------
    real skew = 0.0;                              // ns, D- later than D+
    wire is_ls = (speed == 2'b10);
    // J: FS D+ high, LS D- high
    wire dp_raw = !l_en ? !is_ls : (l_se0 ? 1'b0 : (l_txd ^ is_ls));
    wire dm_raw = !l_en ?  is_ls : (l_se0 ? 1'b0 : !(l_txd ^ is_ls));
    reg  rxdp = 1'b1, rxdm = 1'b0, rxrcv = 1'b1;
    always @(dp_raw) rxdp  <= #(0.2) dp_raw;
    always @(dm_raw) rxdm  <= #(0.2 + skew) dm_raw;
    always @(dp_raw) rxrcv <= #(0.2 + skew / 2.0) dp_raw;

    // ---------------- DUT ----------------
    wire       rx_start, rx_valid, rx_end, rx_error, rx_busy;
    wire [7:0] rx_data;

    usb_rx_datapath #(
        .FS_DIV (FS_DIV), .LS_DIV (LS_DIV), .DIV_W (9), .HOLDOFF (HOLDOFF)
    ) dut (
        .clk_bit     (clk_bit),
        .rst_n       (rst_n),
        .ce60        (ce60),
        .speed       (speed),
        .rx_en       (rx_en),
        .tx_en       (loc_tx),
        .clk_rx      (clk_rx),
        .hs_rxd      (hs_rxd),
        .hs_squelch  (hs_sq),
        .hs_cdr_lock (hs_lk),
        .rxrcv       (rxrcv),
        .rxdp        (rxdp),
        .rxdm        (rxdm),
        .rx_start    (rx_start),
        .rx_valid    (rx_valid),
        .rx_data     (rx_data),
        .rx_end      (rx_end),
        .rx_error    (rx_error),
        .rx_busy     (rx_busy)
    );

    // ---------------- ULPI RX Data Handler behind the datapath ----------------
    wire       rxa, rxe, rxd_valid, overrun;
    wire [7:0] rxd_data;
    reg  [1:0] sent_rxev = 2'b00;
    always @(posedge clk_bit) if (ce60) sent_rxev <= {rxe, rxa};

    usb_ulpi_rx_handler #(.DEPTH(8)) u_hdl (
        .clk       (clk_bit),
        .rst_n     (rst_n),
        .ce        (ce60),
        .rx_start  (rx_start),
        .rx_valid  (rx_valid),
        .rx_data   (rx_data),
        .rx_end    (rx_end),
        .rx_error  (rx_error),
        .rx_abort  (1'b0),
        .sent_rxev (sent_rxev),
        .rxa       (rxa),
        .rxe       (rxe),
        .rxd_valid (rxd_valid),
        .rxd_data  (rxd_data),
        .rxd_ready (rxd_valid && ce60),
        .overrun   (overrun)
    );

    // ---------------- expected packets ----------------
    reg [7:0] e_b   [0:262143];
    integer   e_off [0:1023];
    integer   e_n   [0:1023];
    reg       e_err [0:1023];
    integer   e_tail = 0, e_head = 0, e_wp = 0;

    task expect_pkt(input integer off_in_f, input integer n, input err);
        integer i;
        begin
            e_off[e_tail] = e_wp;
            e_n[e_tail]   = n;
            e_err[e_tail] = err;
            for (i = 0; i < n; i = i + 1) begin
                e_b[e_wp] = f_b[off_in_f + i];
                e_wp = e_wp + 1;
            end
            e_tail = e_tail + 1;
        end
    endtask

    // ---------------- output checker (one look per tick) ----------------
    reg     in_pkt = 1'b0;
    reg [7:0] rb [0:4095];
    integer nrx = 0;
    integer pkts_rx = 0, bytes_rx = 0, err_pkts = 0;
    reg [7:0] hq [0:65535];                       // datapath bytes -> handler check
    integer hq_w = 0, hq_r = 0;

    task check_end;
        integer i, n, o;
        reg mism;
        begin
            if (e_head >= e_tail) begin
                errors = errors + 1;
                $display("ERROR @%0t: packet received (%0d bytes), none expected", $time, nrx);
            end else begin
                n = e_n[e_head];
                o = e_off[e_head];
                mism = 1'b0;
                if (e_err[e_head]) begin
                    if (!rx_error) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet %0d: rx_error expected", $time, e_head);
                    end
                    if (nrx > n + 1) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet %0d: %0d bytes, at most %0d expected", $time, e_head, nrx, n + 1);
                    end
                    // the byte in which the error happened may be garbage
                    for (i = 0; i + 1 < nrx && i < n; i = i + 1)
                        if (!mism && rb[i] !== e_b[o + i]) mism = 1'b1;
                    err_pkts = err_pkts + 1;
                end else begin
                    if (rx_error) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet %0d: unexpected rx_error (%0d bytes)", $time, e_head, nrx);
                    end
                    if (nrx != n) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: packet %0d: %0d bytes, expected %0d", $time, e_head, nrx, n);
                    end
                    for (i = 0; i < nrx && i < n; i = i + 1)
                        if (!mism && rb[i] !== e_b[o + i]) begin
                            mism = 1'b1;
                            $display("ERROR @%0t: packet %0d byte %0d = %02h, expected %02h",
                                     $time, e_head, i, rb[i], e_b[o + i]);
                        end
                end
                if (mism) begin
                    errors = errors + 1;
                    if (e_err[e_head]) $display("ERROR @%0t: packet %0d: bytes are not a prefix", $time, e_head);
                end
                e_head = e_head + 1;
            end
        end
    endtask

    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            if ((rx_start + rx_valid + rx_end) > 1) begin
                errors = errors + 1;
                $display("ERROR @%0t: more than one RX event in a tick", $time);
            end
            if (rx_error && !rx_end) begin
                errors = errors + 1;
                $display("ERROR @%0t: rx_error without rx_end", $time);
            end
            if (rx_start) begin
                if (in_pkt) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: rx_start inside a packet", $time);
                end
                in_pkt = 1'b1;
                nrx    = 0;
            end
            if (rx_valid) begin
                if (!in_pkt) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: rx_valid outside a packet", $time);
                end
                if (nrx < 4096) rb[nrx] = rx_data;
                nrx      = nrx + 1;
                bytes_rx = bytes_rx + 1;
                hq[hq_w % 65536] = rx_data;
                hq_w = hq_w + 1;
            end
            if (rx_end) begin
                if (!in_pkt) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: rx_end outside a packet", $time);
                end else begin
                    check_end;
                end
                in_pkt  = 1'b0;
                pkts_rx = pkts_rx + 1;
            end

            // RX Data Handler output
            if (overrun) begin
                errors = errors + 1;
                $display("ERROR @%0t: RX Data Handler overrun", $time);
            end
            if (rxd_valid) begin
                if (hq_r >= hq_w) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: handler byte %02h without datapath byte", $time, rxd_data);
                end else begin
                    if (rxd_data !== hq[hq_r % 65536]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: handler byte %02h, datapath byte %02h", $time, rxd_data, hq[hq_r % 65536]);
                    end
                    hq_r = hq_r + 1;
                end
            end
        end
    end

    // ---------------- stimulus helpers ----------------
    task set_ppm(input real ppm);
        begin
            far_half = HALF / (1.0 + ppm * 1.0e-6);
        end
    endtask

    task set_speed(input [1:0] s);
        begin
            @(negedge clk_bit);
            speed   = s;
            bit_div = (s == 2'b00) ? 1 : ((s == 2'b10) ? LS_DIV : FS_DIV);
            repeat (200) @(posedge clk_bit);
        end
    endtask

    // build SYNC + PID + payload in f_b; returns the offset of the PID
    integer pid_off;
    task build(input [3:0] pid, input integer npay);
        integer i;
        reg [31:0] r;
        begin
            f_n = 0;
            if (speed == 2'b00) begin
                f_b[0] = 8'h00; f_b[1] = 8'h00; f_b[2] = 8'h00; f_b[3] = 8'h80; f_n = 4;
            end else begin
                f_b[0] = 8'h80; f_n = 1;
            end
            pid_off = f_n;
            f_b[f_n] = {~pid, pid}; f_n = f_n + 1;
            for (i = 0; i < npay; i = i + 1) begin
                r = $random(seed);
                case (r[10:8])
                    3'd0:    f_b[f_n] = 8'hFF;
                    3'd1:    f_b[f_n] = 8'h00;
                    3'd2:    f_b[f_n] = 8'h7E;
                    default: f_b[f_n] = r[7:0];
                endcase
                f_n = f_n + 1;
            end
        end
    endtask

    task wait_line_idle;
        integer gap;
        begin
            while (f_go || f_busy || r_go || l_en) @(posedge clk_far);
            gap = (speed == 2'b00) ? 60 : 4 * bit_div;
            repeat (gap) @(posedge clk_far);
        end
    endtask

    task wait_rx(input integer target);
        integer t;
        begin
            t = 0;
            while ((pkts_rx < target) && (t < 4000)) begin
                @(posedge clk_bit);
                t = t + 1;
            end
            if (pkts_rx < target) begin
                errors = errors + 1;
                $display("ERROR @%0t: packet %0d not received", $time, target - 1);
                pkts_rx = target;
                e_head  = target;
            end
            repeat (20) @(posedge clk_bit);
        end
    endtask

    task randomize_line;
        begin
            sq_on  = 1 + {$random(seed)} % 8;
            lk_on  = 1 + {$random(seed)} % 12;       // 2..20 SYNC bits lost
            sq_off = 2 + {$random(seed)} % 7;
            skew   = ({$random(seed)} % 60) / 10.0;  // 0..5.9 ns
        end
    endtask

    // send f_b through the far transmitter; exp: 0 not received, 1 ok, 2 error
    task send(input integer exp);
        integer target;
        begin
            randomize_line;
            raw_mode = 1'b0;
            if (exp != 0) expect_pkt(pid_off, f_n - pid_off, exp == 2);
            target = pkts_rx + ((exp != 0) ? 1 : 0);
            @(posedge clk_far);
            f_idx = 0;
            f_go  = 1'b1;
            @(posedge clk_far);
            wait_line_idle;
            if (exp != 0) wait_rx(target);
            else          repeat (400) @(posedge clk_bit);
        end
    endtask

    task send_pkt(input [3:0] pid, input integer npay);
        begin
            build(pid, npay);
            send(1);
        end
    endtask

    // ---------------- raw line patterns ----------------
    // NRZI + stuffing of f_b[0 .. f_n-1] into r_sym, starting from J.
    //   viol_at >= 0 : before data bit viol_at (counted from the first PID bit),
    //                  send seven 1s without a stuff bit
    //   extra        : number of additional 0 bits before the EOP
    //   eop          : 1 = append the EOP of the current speed
    task build_raw(input integer viol_at, input integer extra, input eop);
        integer i, j, k, ones, dbit;
        reg     lvl, b;
        begin
            r_n  = 0;
            lvl  = 1'b1;
            ones = 0;
            for (i = 0; i < f_n; i = i + 1) begin
                for (j = 0; j < 8; j = j + 1) begin
                    dbit = (i - pid_off) * 8 + j;
                    if ((viol_at >= 0) && (dbit == viol_at)) begin
                        for (k = 0; k < 7; k = k + 1) begin
                            r_sym[r_n] = lvl; r_n = r_n + 1;
                        end
                        ones = 0;
                    end
                    b = f_b[i][j];
                    if (!b) lvl = ~lvl;
                    r_sym[r_n] = lvl; r_n = r_n + 1;
                    if (b) ones = ones + 1; else ones = 0;
                    if (ones == 6) begin
                        lvl = ~lvl;
                        r_sym[r_n] = lvl; r_n = r_n + 1;
                        ones = 0;
                    end
                end
            end
            for (k = 0; k < extra; k = k + 1) begin
                lvl = ~lvl;
                r_sym[r_n] = lvl; r_n = r_n + 1;
            end
            if (eop) begin
                if (speed == 2'b00) begin
                    lvl = ~lvl;
                    for (k = 0; k < 8; k = k + 1) begin
                        r_sym[r_n] = lvl; r_n = r_n + 1;
                    end
                end else begin
                    r_sym[r_n] = 2'd2; r_n = r_n + 1;
                    r_sym[r_n] = 2'd2; r_n = r_n + 1;
                    r_sym[r_n] = 2'd1; r_n = r_n + 1;
                end
            end
        end
    endtask

    task send_raw(input integer exp);
        integer target;
        begin
            randomize_line;
            raw_mode = 1'b1;
            if (exp != 0) expect_pkt(pid_off, f_n - pid_off, exp == 2);
            target = pkts_rx + ((exp != 0) ? 1 : 0);
            @(posedge clk_far);
            r_i   = 0;
            r_cnt = 0;
            r_go  = 1'b1;
            @(posedge clk_far);
            wait_line_idle;
            raw_mode = 1'b0;
            if (exp != 0) wait_rx(target);
            else          repeat (400) @(posedge clk_bit);
        end
    endtask

    // ---------------- test sequences ----------------
    task hs_run(input real ppm, input integer npk);
        integer p;
        begin
            set_ppm(ppm);
            set_speed(2'b00);
            send_pkt(4'h2, 0);                       // ACK
            send_pkt(4'h3, 1023);                    // longest HS packet: PID + 1024 + CRC16
            send_pkt(4'hB, 1);
            for (p = 0; p < npk; p = p + 1)
                send_pkt($random(seed), {$random(seed)} % 70);
            send_pkt(4'hB, 511);
        end
    endtask

    task fsls_run(input [1:0] s, input real ppm, input integer npk, input integer maxlen);
        integer p;
        begin
            set_ppm(ppm);
            set_speed(s);
            send_pkt(4'h2, 0);
            for (p = 0; p < npk; p = p + 1)
                send_pkt($random(seed), {$random(seed)} % (maxlen + 1));
        end
    endtask

    initial begin
        $dumpfile("tb_usb_rx_datapath.vcd");
        $dumpvars(0, tb_usb_rx_datapath);

        rst_n = 1'b0;
        repeat (10) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (50) @(posedge clk_bit);

        $display("HS, 0 ppm");
        hs_run(0.0, 30);
        $display("HS, +1000 ppm (far end faster)");
        hs_run(1000.0, 15);
        $display("HS, -1000 ppm (far end slower)");
        hs_run(-1000.0, 15);

        $display("FS, 0 / +2500 / -2500 ppm, D+/D- skew");
        fsls_run(2'b01, 0.0, 12, 20);
        fsls_run(2'b01, 2500.0, 8, 20);
        fsls_run(2'b01, -2500.0, 8, 20);
        $display("XcvrSelect 11 (FS)");
        fsls_run(2'b11, 0.0, 3, 8);
        $display("LS, +15000 / -15000 ppm");
        fsls_run(2'b10, 15000.0, 3, 6);
        fsls_run(2'b10, -15000.0, 3, 6);

        // ---------------- errors and special cases ----------------
        $display("FS errors: stuff violation, EOP not on a byte boundary");
        set_ppm(0.0);
        set_speed(2'b01);
        build(4'h3, 6); build_raw(-1, 0, 1); send_raw(1);       // raw path itself is fine
        build(4'h3, 6); build_raw(19, 0, 1); send_raw(2);       // seven 1s inside the data
        build(4'h3, 6); build_raw(-1, 3, 1); send_raw(2);       // 3 extra bits before the EOP
        send_pkt(4'h2, 2);                                       // recovers
        $display("LS keep-alive (EOP only) is not a packet");
        set_speed(2'b10);
        f_n = 0; pid_off = 0; build_raw(-1, 0, 1); send_raw(0);
        send_pkt(4'h2, 1);

        $display("HS errors: EOP not on a byte boundary, stuff violation, squelch");
        set_speed(2'b00);
        build(4'h3, 20); build_raw(-1, 0, 1); send_raw(1);
        build(4'h3, 20); build_raw(-1, 3, 1); send_raw(2);
        build(4'h3, 20); build_raw(8 * 5 + 3, 0, 1); send_raw(2);
        build(4'hB, 60);
        fork
            send(2);
            begin                                                // squelch from the middle on
                repeat (400) @(posedge clk_far);
                sq_force = 1'b1;
                while (l_en) @(posedge clk_far);
                sq_force = 1'b0;
            end
        join
        send_pkt(4'h2, 4);

        $display("Local transmitter: no reception during and right after it");
        loc_tx = 1'b1;
        build(4'h3, 10); send(0);
        loc_tx = 1'b0;
        repeat (HOLDOFF + 40) @(posedge clk_bit);
        send_pkt(4'h3, 10);
        set_speed(2'b01);
        loc_tx = 1'b1;
        build(4'h3, 3); send(0);
        loc_tx = 1'b0;
        repeat (HOLDOFF + 40) @(posedge clk_bit);
        send_pkt(4'h3, 3);

        $display("rx_en = 0");
        set_speed(2'b00);
        rx_en = 1'b0;
        build(4'h3, 5); send(0);
        rx_en = 1'b1;
        send_pkt(4'h3, 5);

        // ---------------- final checks ----------------
        repeat (200) @(posedge clk_bit);
        if (e_head != e_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d packets expected, %0d checked", e_tail, e_head);
        end
        if (hq_r != hq_w) begin
            errors = errors + 1;
            $display("ERROR: handler forwarded %0d of %0d bytes", hq_r, hq_w);
        end
        $display("%0d packets (%0d with expected errors), %0d bytes received", pkts_rx, err_pkts, bytes_rx);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #60_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
