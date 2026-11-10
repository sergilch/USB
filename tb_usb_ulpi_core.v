//-----------------------------------------------------------------------------
// tb_usb_ulpi_core.v - end-to-end testbench for usb_ulpi_core
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_core usb_ulpi_input_capture.v usb_ulpi_bus_owner.v \
//            usb_ulpi_reg_access.v usb_ulpi_burst_mux.v usb_tx_holding.v usb_tx_sync_mux.v \
//            usb_bit_stuffer.v usb_nrzi_encoder.v usb_tx_serializer.v usb_tx_path.v \
//            usb_tx_datapath.v usb_ulpi_core.v tb_usb_ulpi_core.v
//   vvp sim_core
//
// Pin level, like a real ULPI system:
//   * a ULPI Link model (clocked on ce60 ticks) executes a queue of operations:
//       - TX packets          TXCMD, payload, STP
//       - register write      RegWrite cmd, data, STP
//       - ext. register write cmd AFh, address, data, STP
//       - register read       RegRead cmd, then the turnaround and the data, strictly
//                             timed (see below)
//       - ext. register read  cmd EFh, address, then the same
//     Every byte is held on the bus until NXT = 1 consumes it.  The Link releases the
//     bus when it sees DIR = 1 and repeats a command that was not acknowledged yet (the
//     PHY wins the collision); it reports an error if DIR rises inside a transfer or if
//     NXT is high while the Link has nothing on the bus.
//   * register data bytes / addresses are often chosen to look like TXCMD / register
//     commands (40h, 4Fh, 80h, AFh, C0h, EFh, 2Fh ...), TX payload bytes are random;
//   * a behavioural Register File (immediate 64 bytes and extended 256 bytes, answer in
//     the same tick as reg_rd, as usb_ulpi_reg_access requires) answers reg_rd / reg_wr;
//   * a PHY burst source (arb_*) competes for the bus.
// Checked
//   * register contents at the end equal a shadow model; every read returns the value
//     that the shadow model predicts at that point of the sequence;
//   * register read timing at the pins (ULPI 1.1 Fig. 22 / 30), the Link takes the data
//     from the pins only: the NXT that consumes the last byte of the read (command or
//     extended address) in tick N, turnaround in N+1, the data with NXT = 0 in N+2,
//     DIR low in N+3;
//   * the bytes on the DIR/NXT/DATA pins are exactly the bytes handed over by the burst
//     mux, in order, with the right NXT marker; a register data byte forms a burst of
//     its own;
//   * every TX packet is rebuilt from txd / tx_en / tx_se0 (gapless timing, EOP, NRZI,
//     de-stuffing) and equals SYNC + PID + payload; tx_underrun never pulses.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_core;

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

    wire       reg_wr, reg_rd, reg_ext;
    wire [7:0] reg_addr, reg_wdata;
    reg  [7:0] reg_rdata;
    wire       rd_valid;

    wire       txd, tx_en, tx_se0;
    wire [1:0] tx_speed;
    wire       busy, tx_done, tx_underrun;

    usb_ulpi_core #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9)) dut (
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
        .reg_wr        (reg_wr),
        .reg_rd        (reg_rd),
        .reg_ext       (reg_ext),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_rdata     (reg_rdata),
        .rd_valid      (rd_valid),
        .txd           (txd),
        .tx_en         (tx_en),
        .tx_se0        (tx_se0),
        .tx_speed      (tx_speed),
        .busy          (busy),
        .tx_done       (tx_done),
        .tx_underrun   (tx_underrun)
    );

    integer errors  = 0;
    integer seed    = 32'h5C5C_5C5C;
    integer seed_lk = 32'h1A1A_1A1A;
    integer seed_rx = 32'h2B2B_2B2B;

    // ---------------- behavioural Register File ----------------
    // Same-tick answer, as usb_ulpi_reg_access requires: reg_rdata combinational from
    // reg_addr / reg_ext, rd_valid = reg_rd.  (Its extended space is a separate memory;
    // the mirror of 00h-3Fh is a property of usb_ulpi_reg_file, not of the core.)
    reg [7:0] mem_imm [0:63];
    reg [7:0] mem_ext [0:255];
    reg [7:0] sh_imm  [0:63];             // shadow model (expected contents)
    reg [7:0] sh_ext  [0:255];

    assign rd_valid = reg_rd;
    always @* reg_rdata = reg_ext ? mem_ext[reg_addr] : mem_imm[reg_addr[5:0]];

    always @(posedge clk_bit) begin
        if (rst_n && ce60 && reg_wr) begin
            if (reg_ext) mem_ext[reg_addr]      = reg_wdata;
            else         mem_imm[reg_addr[5:0]] = reg_wdata;
        end
    end

    integer ii;
    initial begin
        for (ii = 0; ii < 64;  ii = ii + 1) begin mem_imm[ii] = 8'd0; sh_imm[ii] = 8'd0; end
        for (ii = 0; ii < 256; ii = ii + 1) begin mem_ext[ii] = 8'd0; sh_ext[ii] = 8'd0; end
    end

    // ---------------- expected TX line packets ----------------
    reg [7:0] q_exp [0:12287];            // 128 slots x 96 bytes
    integer   q_len [0:127];
    reg [1:0] q_spd [0:127];
    reg       q_byp [0:127];
    integer   q_head = 0;
    integer   q_tail = 0;
    integer   pkts_checked = 0;
    integer   done_cnt     = 0;

    reg [7:0] src_bytes [0:63];

    // ---------------- expected register read data ----------------
    reg [7:0] exp_rd [0:1023];
    integer   exp_rd_n = 0;
    integer   rd_cnt   = 0;
    reg       ret_seen = 1'b0;

    // ---------------- Link operation queue ----------------
    reg [7:0] op_cmd [0:255];
    integer   op_nb  [0:255];
    reg       op_stp [0:255];
    reg [7:0] op_by  [0:16383];           // 256 slots x 64 bytes
    integer   op_head = 0;
    integer   op_tail = 0;

    integer   lk_state = 0;               // 0 idle, 1 cmd, 2 data, 3 STP, 4 read turnaround / data
    integer   rd_t     = 0;               // ticks since the NXT that ended a read
    integer   lk_rd    = 0;               // read data bytes taken by the Link
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
            h = op_head % 256;
            // strict register read timing (ULPI 1.1 Fig. 22 / 30), pins only: NXT for the
            // last byte in tick N, turnaround (DIR = 1, bus not driven) in N+1, the data
            // with NXT = 0 in N+2, DIR low in N+3
            if (lk_state == 4) begin
                rd_t = rd_t + 1;
                if (rd_t == 1) begin
                    if (!(ulpi_dir && !ulpi_data_oe)) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: no turnaround in the cycle after the read NXT (dir %b oe %b)", $time, ulpi_dir, ulpi_data_oe);
                    end
                end else if (rd_t == 2) begin
                    if (!(ulpi_dir && ulpi_data_oe)) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: no read data in the second cycle after the read NXT", $time);
                    end else begin
                        if (ulpi_nxt) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: NXT high with the register read data", $time);
                        end
                        if (ulpi_data_out !== exp_rd[lk_rd]) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: Link read %0d got %02h at the pins, expected %02h", $time, lk_rd, ulpi_data_out, exp_rd[lk_rd]);
                        end
                    end
                    lk_rd = lk_rd + 1;
                end else if ((rd_t == 3) && ulpi_dir) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR still high in the third cycle after the read NXT", $time);
                end else if (rd_t > 40) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: register read never finished", $time);
                    rd_t = 3;
                end
            end
            if (ulpi_dir) begin
                if ((lk_state == 2) || (lk_state == 3)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose inside a Link transfer", $time);
                end
                lk_data <= 8'd0;
                lk_stp  <= 1'b0;
                if (lk_state == 1) begin           // command not acknowledged: PHY won, retry later
                    lk_state   = 0;
                    lk_retries = lk_retries + 1;
                    lk_gap     = 0;
                end
            end else begin
                if (ulpi_nxt && ((lk_state == 0) || (lk_state == 4))) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: NXT high while the Link has nothing on the bus", $time);
                end
                case (lk_state)
                    0: begin
                        lk_data <= 8'd0;
                        lk_stp  <= 1'b0;
                        if (lk_gap > 0) begin
                            lk_gap = lk_gap - 1;
                        end else if (op_head != op_tail) begin
                            lk_data  <= op_cmd[h];
                            lk_state = 1;
                        end
                    end
                    1: begin
                        if (ulpi_nxt) begin
                            if (op_nb[h] > 0) begin
                                lk_idx   = 0;
                                lk_data <= op_by[h * 64];
                                lk_state = 2;
                            end else if (op_stp[h]) begin
                                lk_data <= 8'd0;
                                lk_stp  <= 1'b1;
                                lk_state = 3;
                            end else begin
                                lk_data <= 8'd0;
                                lk_state = 4;
                                rd_t     = 0;
                            end
                        end
                    end
                    2: begin
                        if (ulpi_nxt) begin
                            lk_idx = lk_idx + 1;
                            if (lk_idx == op_nb[h]) begin
                                lk_data <= 8'd0;
                                if (op_stp[h]) begin
                                    lk_stp  <= 1'b1;
                                    lk_state = 3;
                                end else begin
                                    lk_state = 4;
                                    rd_t     = 0;
                                end
                            end else begin
                                lk_data <= op_by[h * 64 + lk_idx];
                            end
                        end
                    end
                    3: begin                        // STP tick
                        lk_stp  <= 1'b0;
                        lk_data <= 8'd0;
                        op_head  = op_head + 1;
                        lk_state = 0;
                        lk_gap   = link_gaps ? ({$random(seed_lk)} % 5) : 0;
                    end
                    default: begin                  // read: done once DIR fell after the data
                        lk_data <= 8'd0;
                        if (rd_t >= 3) begin
                            ret_seen = 1'b0;
                            op_head  = op_head + 1;
                            lk_state = 0;
                            lk_gap   = link_gaps ? ({$random(seed_lk)} % 5) : 0;
                        end
                    end
                endcase
            end
        end
    end

    // ---------------- PHY burst source (arb_*) ----------------
    reg [7:0] rb_b   [0:4095];            // 256 bursts x 16 bytes
    reg       rb_d   [0:4095];
    integer   rb_len [0:255];
    integer   rb_i = 0;
    integer   rb_k = 0;
    integer   rb_n = 0;
    integer   ext_total = 0;             // PHY-burst bytes queued so far
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
            ext_total    = ext_total + n;
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                rb_b[rb_n * 16 + i] = r[7:0];
                rb_d[rb_n * 16 + i] = r[8];
            end
            rb_n = rb_n + 1;
        end
    endtask

    // ---------------- bytes handed to the bus owner / seen on the pins ----------------
    reg [7:0] log_b   [0:8191];
    reg       log_d   [0:8191];
    reg       log_reg [0:8191];
    integer   log_n   = 0;               // bytes consumed by the bus owner
    integer   pin_n   = 0;               // bytes seen on the pins
    reg       prev_oe = 1'b0;
    reg       reg_end_pending = 1'b0;
    integer   ext_seen = 0;              // PHY-burst bytes seen on the pins

    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            // consumption by the bus owner (pre-edge values)
            if (dut.rg_burst_ready) begin
                log_b[log_n]   = dut.rg_burst_data;
                log_d[log_n]   = 1'b0;
                log_reg[log_n] = 1'b1;
                log_n = log_n + 1;
                if (rd_cnt >= exp_rd_n) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: unexpected register read data %02h", $time, dut.rg_burst_data);
                end else if (dut.rg_burst_data !== exp_rd[rd_cnt]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: register read %0d returned %02h, expected %02h",
                             $time, rd_cnt, dut.rg_burst_data, exp_rd[rd_cnt]);
                end
                rd_cnt   = rd_cnt + 1;
                ret_seen = 1'b1;
            end else if (arb_ready) begin
                log_b[log_n]   = arb_data;
                log_d[log_n]   = arb_is_data;
                log_reg[log_n] = 1'b0;
                log_n = log_n + 1;
            end

            // pins, as the Link sees them
            if (ulpi_data_oe && !ulpi_dir) begin
                errors = errors + 1;
                $display("ERROR @%0t: ulpi_data_oe without DIR", $time);
            end
            if (ulpi_dir && !ulpi_data_oe && ulpi_nxt) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT high in an undriven DIR tick", $time);
            end
            if (reg_end_pending && ulpi_data_oe) begin
                errors = errors + 1;
                $display("ERROR @%0t: register data merged into a longer burst", $time);
            end
            reg_end_pending = 1'b0;
            if (ulpi_data_oe) begin
                if (pin_n >= log_n) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: byte %02h on the pins that nobody handed over", $time, ulpi_data_out);
                end else begin
                    if (ulpi_data_out !== log_b[pin_n]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: pin byte %0d = %02h, expected %02h", $time, pin_n, ulpi_data_out, log_b[pin_n]);
                    end
                    if (ulpi_nxt !== log_d[pin_n]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: NXT = %b with pin byte %0d, expected %b", $time, ulpi_nxt, pin_n, log_d[pin_n]);
                    end
                    if (log_reg[pin_n]) begin
                        if (prev_oe) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: register data does not start a burst", $time);
                        end
                        reg_end_pending = 1'b1;
                    end else begin
                        ext_seen = ext_seen + 1;
                    end
                    pin_n = pin_n + 1;
                end
            end
            prev_oe = ulpi_data_oe;
        end
    end

    // ---------------- TX line monitor / decoder ----------------
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

    // ---------------- operation queue helpers ----------------
    task push_op(input [7:0] cmd, input integer nb, input stp);
        integer oi;
        begin
            oi = op_tail % 256;
            op_cmd[oi] = cmd;
            op_nb[oi]  = nb;
            op_stp[oi] = stp;
            op_tail    = op_tail + 1;
        end
    endtask

    task set_byte(input integer b, input [7:0] v);     // payload byte of the op being queued
        begin
            op_by[(op_tail % 256) * 64 + b] = v;
        end
    endtask

    task q_tx(input [3:0] pid, input nopid, input integer nb);
        integer i, k, qi;
        begin
            for (i = 0; i < nb; i = i + 1) set_byte(i, src_bytes[i]);
            push_op(nopid ? 8'h40 : {4'h4, pid}, nb, 1'b1);

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
            if (k != 0) begin
                q_len[qi] = k;
                q_spd[qi] = speed;
                q_byp[qi] = bypass_en;
                q_tail    = q_tail + 1;
            end
        end
    endtask

    task q_wr(input [5:0] a, input [7:0] d);
        begin
            set_byte(0, d);
            push_op({2'b10, a}, 1, 1'b1);
            sh_imm[a] = d;
        end
    endtask

    task q_wx(input [7:0] a, input [7:0] d);
        begin
            set_byte(0, a);
            set_byte(1, d);
            push_op(8'hAF, 2, 1'b1);
            sh_ext[a] = d;
        end
    endtask

    task q_rd(input [5:0] a);
        begin
            push_op({2'b11, a}, 0, 1'b0);
            exp_rd[exp_rd_n] = sh_imm[a];
            exp_rd_n = exp_rd_n + 1;
        end
    endtask

    task q_rx(input [7:0] a);
        begin
            set_byte(0, a);
            push_op(8'hEF, 1, 1'b0);
            exp_rd[exp_rd_n] = sh_ext[a];
            exp_rd_n = exp_rd_n + 1;
        end
    endtask

    // random helpers
    function [7:0] special_byte(input [31:0] r);
        begin
            case (r % 8)
                0: special_byte = 8'h40;
                1: special_byte = 8'h4F;
                2: special_byte = 8'h80;
                3: special_byte = 8'hAF;
                4: special_byte = 8'hC0;
                5: special_byte = 8'hEF;
                6: special_byte = 8'h41;
                default: special_byte = 8'h2F;
            endcase
        end
    endfunction

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

    task rand_op(input integer allow_tx, input integer maxpay);
        reg [31:0] r, r2;
        integer kind, nb;
        reg [5:0] a6;
        reg [7:0] a8, d8;
        begin
            r    = $random(seed);
            kind = (allow_tx != 0) ? (r[15:8] % 5) : (1 + (r[15:8] % 4));
            r2   = $random(seed);
            a6   = r[5:0];
            if (a6 == 6'h2F) a6 = 6'h2E;                           // 2Fh is the extended pointer
            a8   = (r2[7:6] == 2'd0) ? special_byte(r2[31:16]) : r[23:16];
            d8   = (r2[5:4] == 2'd0) ? special_byte(r2[31:8])  : r2[15:8];
            case (kind)
                0: begin
                       nb = {$random(seed)} % (maxpay + 1);
                       fill(nb);
                       if (r[28:24] == 5'd0 && nb == 0) begin
                           q_tx(4'h0, 1'b1, 0);                    // NOPID, SYNC only
                       end else begin
                           q_tx((r[27:24] == 4'd0) ? 4'd1 : r[27:24], 1'b0, nb);
                       end
                   end
                1: q_wr(a6, d8);
                2: q_wx(a8, d8);
                3: q_rd(a6);
                default: q_rx(a8);
            endcase
        end
    endtask

    task rand_burst;
        begin
            queue_burst(1 + ({$random(seed)} % 8));
        end
    endtask

    task finish_all;
        begin
            while (!((op_head == op_tail) && (lk_state == 0) && (rb_i == rb_n) && (ext_seen == ext_total)
                     && (pkts_checked == q_tail) && (rd_cnt == exp_rd_n))) @(posedge clk_bit);
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

    // ---------------- stimulus ----------------
    integer g, p, mism_n;

    initial begin
        $dumpfile("tb_usb_ulpi_core.vcd");
        $dumpvars(0, tb_usb_ulpi_core);

        rst_n = 1'b0;
        repeat (5) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (10) @(posedge clk_bit);

        // ---------------- directed register accesses ----------------
        $display("Directed register accesses");
        set_cfg(2'b00, 1'b0, 1'b0);
        q_wr(6'h04, 8'h41);          q_rd(6'h04);                   // value that looks like a PID TXCMD
        q_wr(6'h07, 8'h80);          q_rd(6'h07);                   // looks like a register write
        q_wr(6'h0A, 8'hEF);          q_rd(6'h0A);                   // looks like an extended read
        q_wx(8'h10, 8'hAF);          q_rx(8'h10);                   // separate ext memory in this TB's RF model
        q_rd(6'h10);                                                // immediate 10h still 0
        q_wx(8'h40, 8'h4F);          q_rx(8'h40);                   // address byte looks like a TXCMD
        q_wx(8'hEF, 8'hC0);          q_rx(8'hEF);
        q_wx(8'h2F, 8'h55);          q_rx(8'h2F);                   // address byte = pointer value
        q_rx(8'h99);                                                // never written
        finish_all;

        $display("Register accesses with PHY bursts");
        for (p = 0; p < 10; p = p + 1) begin
            rand_op(0, 0);
            rand_burst;
        end
        finish_all;

        $display("Mixed HS: TX packets, register accesses and PHY bursts compete for the bus");
        for (g = 0; g < 8; g = g + 1) begin
            set_cfg(2'b00, 1'b0, 1'b0);
            link_gaps = (g % 2);
            rx_gaps   = (g % 3) != 0;
            for (p = 0; p < 8; p = p + 1) begin
                rand_op(1, 16);
                if (p % 2) rand_burst;
            end
            finish_all;
        end

        $display("HS streaming: no gaps anywhere");
        for (g = 0; g < 3; g = g + 1) begin
            set_cfg(2'b00, 1'b0, 1'b0);
            link_gaps = 1'b0;
            rx_gaps   = 1'b0;
            for (p = 0; p < 8; p = p + 1) begin
                rand_op(1, 24);
                if (p % 3 == 0) rand_burst;
            end
            finish_all;
        end

        $display("Mixed FS");
        for (g = 0; g < 2; g = g + 1) begin
            set_cfg(2'b01, 1'b0, 1'b0);
            link_gaps = 1'b1;
            rx_gaps   = 1'b1;
            for (p = 0; p < 6; p = p + 1) begin
                rand_op(1, 8);
                if (p % 2) rand_burst;
            end
            finish_all;
        end

        // ---------------- final checks ----------------
        repeat (20) @(posedge clk_bit);
        mism_n = 0;
        for (ii = 0; ii < 64;  ii = ii + 1) if (mem_imm[ii] !== sh_imm[ii]) mism_n = mism_n + 1;
        for (ii = 0; ii < 256; ii = ii + 1) if (mem_ext[ii] !== sh_ext[ii]) mism_n = mism_n + 1;
        if (mism_n != 0) begin
            errors = errors + 1;
            $display("ERROR: %0d register(s) differ from the shadow model", mism_n);
        end
        if (pkts_checked != q_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d TX packets expected on the line, %0d seen", q_tail, pkts_checked);
        end
        if (done_cnt != q_tail) begin
            errors = errors + 1;
            $display("ERROR: tx_done pulses = %0d, packets = %0d", done_cnt, q_tail);
        end
        if (lk_rd != exp_rd_n) begin
            errors = errors + 1;
            $display("ERROR: %0d register reads queued, %0d taken by the Link at the pins", exp_rd_n, lk_rd);
        end
        if (rd_cnt != exp_rd_n) begin
            errors = errors + 1;
            $display("ERROR: %0d register reads queued, %0d returned", exp_rd_n, rd_cnt);
        end
        if (pin_n != log_n) begin
            errors = errors + 1;
            $display("ERROR: %0d bytes handed to the bus owner, %0d seen on the pins", log_n, pin_n);
        end
        if (busy !== 1'b0 || tx_en !== 1'b0 || ulpi_dir !== 1'b0 || ulpi_nxt !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not idle at the end");
        end

        $display("--------------------------------------------------");
        $display("TX packets: %0d, register reads: %0d, PHY bytes: %0d, Link retries after losing the bus: %0d",
                 pkts_checked, rd_cnt, ext_seen, lk_retries);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #100_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
