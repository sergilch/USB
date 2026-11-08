//-----------------------------------------------------------------------------
// tb_usb_ulpi_phy_if.v - testbench for the RX side of usb_ulpi_phy_if
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_phy usb_ulpi_input_capture.v usb_ulpi_bus_owner.v \
//            usb_ulpi_reg_access.v usb_ulpi_burst_mux.v usb_tx_holding.v usb_tx_sync_mux.v \
//            usb_bit_stuffer.v usb_nrzi_encoder.v usb_tx_serializer.v usb_tx_path.v \
//            usb_tx_datapath.v usb_ulpi_core.v usb_ulpi_rx_handler.v usb_ulpi_rxcmd_gen.v \
//            usb_ulpi_out_arbiter.v usb_ulpi_rx_path.v usb_ulpi_phy_if.v tb_usb_ulpi_phy_if.v
//   vvp sim_phy
//
// An RX datapath model delivers packets (rx_start, rx_valid / rx_data, rx_error, rx_end)
// at a configurable byte spacing (HS: every tick, FS: every 40 ticks); the status inputs
// (LineState, VbusState, HostDisconnect, IdGnd, ALT_INT) change, and the Link side watches
// the ULPI pins.  A pin-level monitor checks, like a Link would see it:
//   * framing: an RXCMD with RxActive = 1 before the first data byte (NXT = 1), data only
//     while RxActive = 1, a closing RXCMD with RxActive = 0, DIR high and the bus driven in
//     every tick in between (the arbiter fills gaps with RXCMD bytes, no toggling of DIR);
//   * every RX packet arrives with all its bytes in order; RxError (RxEvent = 11) is
//     reported for packets with an error and not otherwise;
//   * the RXCMD content equals {ALT_INT, ID, RxEvent, VbusState, LineState} of that tick,
//     and the pin bytes equal what the arbiter handed over;
//   * Link abort: STP while DIR = 1 stops the delivery of the packet and closes RxActive;
//   * interrupt-mask gating of the RXCMD triggers (directed cases with expected counts);
//   * FIFO overflow: an RX packet that arrives while a TX packet keeps the bus busy loses
//     bytes but reports RxError once the bus is free.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_phy_if;

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
    reg  [7:0] lk_data = 8'd0;
    reg        tx_stp  = 1'b0;            // STP of a TX packet (Link model)
    reg        ab_stp  = 1'b0;            // STP used to abort a receive
    wire       lk_stp  = tx_stp | ab_stp;
    wire       ulpi_dir, ulpi_nxt, ulpi_data_oe;
    wire [7:0] ulpi_data_out;

    reg        rx_start = 1'b0, rx_valid = 1'b0, rx_end = 1'b0, rx_error = 1'b0;
    reg  [7:0] rx_data  = 8'd0;

    reg  [1:0] linestate = 2'd0, vbusstate = 2'd0;
    reg        host_disc = 1'b0, id_gnd = 1'b0, alt_int = 1'b0;
    reg  [4:0] ie_rise = 5'd0, ie_fall = 5'd0;

    wire       reg_wr, reg_rd, reg_ext;
    wire [7:0] reg_addr, reg_wdata;
    wire       txd, tx_en, tx_se0, busy, tx_done, tx_underrun;
    wire [1:0] tx_speed;
    wire       rx_active, rx_err, rx_overrun;

    usb_ulpi_phy_if #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(9), .RX_DEPTH(8)) dut (
        .clk_bit       (clk_bit),
        .rst_n         (rst_n),
        .ce60          (ce60),
        .ulpi_data_in  (lk_data),
        .ulpi_stp      (lk_stp),
        .ulpi_dir      (ulpi_dir),
        .ulpi_nxt      (ulpi_nxt),
        .ulpi_data_out (ulpi_data_out),
        .ulpi_data_oe  (ulpi_data_oe),
        .speed         (2'b00),
        .bypass_en     (1'b0),
        .sync_dis      (1'b0),
        .dir_hold      (1'b0),
        .rx_start      (rx_start),
        .rx_valid      (rx_valid),
        .rx_data       (rx_data),
        .rx_end        (rx_end),
        .rx_error      (rx_error),
        .linestate     (linestate),
        .vbusstate     (vbusstate),
        .host_disc     (host_disc),
        .id_gnd        (id_gnd),
        .alt_int       (alt_int),
        .ie_rise       (ie_rise),
        .ie_fall       (ie_fall),
        .reg_wr        (reg_wr),
        .reg_rd        (reg_rd),
        .reg_ext       (reg_ext),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_rdata     (8'd0),
        .rd_valid      (1'b0),
        .txd           (txd),
        .tx_en         (tx_en),
        .tx_se0        (tx_se0),
        .tx_speed      (tx_speed),
        .busy          (busy),
        .tx_done       (tx_done),
        .tx_underrun   (tx_underrun),
        .rx_active     (rx_active),
        .rx_err        (rx_err),
        .rx_overrun    (rx_overrun)
    );

    integer errors = 0;
    integer seed   = 32'h7E57_0001;

    // ---------------- RX packet queue and RX datapath model ----------------
    reg [7:0] pk_data [0:8191];           // 128 slots x 64 bytes
    integer   pk_len  [0:127];
    integer   pk_sp   [0:127];            // byte spacing in ticks
    integer   pk_err  [0:127];            // index of the byte with rx_error, -1 none
    integer   pk_ab   [0:127];            // Link aborts after this many delivered bytes, 0 none
    reg       pk_loss [0:127];            // data loss allowed (overflow / abort)
    reg       pk_experr [0:127];          // RxError must be reported
    integer   pk_n   = 0;                 // queued
    integer   pk_i   = 0;                 // in the RX source
    integer   pk_chk = 0;                 // closed on the pins
    integer   idle_gap = 30;

    integer   rs_state = 0, rs_k = 0, rs_cnt = 0, rs_gap = 10;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            rx_start <= 1'b0; rx_valid <= 1'b0; rx_end <= 1'b0; rx_error <= 1'b0; rx_data <= 8'd0;
        end else if (ce60) begin
            rx_start <= 1'b0;
            rx_valid <= 1'b0;
            rx_end   <= 1'b0;
            rx_error <= 1'b0;
            if (rs_state == 0) begin
                if (pk_i < pk_n) begin
                    if (rs_gap > 0) begin
                        rs_gap = rs_gap - 1;
                    end else begin
                        rx_start <= 1'b1;
                        rs_state = 1;
                        rs_k     = 0;
                        rs_cnt   = 1;
                    end
                end
            end else begin
                rs_cnt = rs_cnt - 1;
                if (rs_cnt <= 0) begin
                    if (rs_k < pk_len[pk_i % 128]) begin
                        rx_valid <= 1'b1;
                        rx_data  <= pk_data[(pk_i % 128) * 64 + rs_k];
                        if (pk_err[pk_i % 128] == rs_k) rx_error <= 1'b1;
                        rs_k   = rs_k + 1;
                        rs_cnt = pk_sp[pk_i % 128];
                    end else begin
                        rx_end   <= 1'b1;
                        pk_i     = pk_i + 1;
                        rs_state = 0;
                        rs_gap   = idle_gap;
                    end
                end
            end
        end
    end

    task q_pkt(input integer n, input integer sp, input integer err_at, input integer ab,
               input loss, input experr);
        integer i, s;
        reg [31:0] r;
        begin
            s = pk_n % 128;
            for (i = 0; i < n; i = i + 1) begin
                r = $random(seed);
                pk_data[s * 64 + i] = r[7:0] | r[15:8];
            end
            pk_len[s]    = n;
            pk_sp[s]     = sp;
            pk_err[s]    = err_at;
            pk_ab[s]     = ab;
            pk_loss[s]   = loss;
            pk_experr[s] = experr;
            pk_n         = pk_n + 1;
        end
    endtask

    // ---------------- TX Link model (only used to keep the bus busy) ----------------
    reg [7:0] tx_by [0:63];
    integer   tx_n       = 0;
    reg       tx_pending = 1'b0;
    integer   tx_state   = 0;
    integer   tx_idx     = 0;
    integer   tx_packets = 0;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            lk_data <= 8'd0;
            tx_stp  <= 1'b0;
        end else if (ce60) begin
            if (ulpi_dir) begin
                lk_data <= 8'd0;
                tx_stp  <= 1'b0;
                if (tx_state == 1) tx_state = 0;              // TXCMD not acknowledged: retry later
                else if ((tx_state == 2) || (tx_state == 3)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose inside a TX packet", $time);
                end
            end else begin
                case (tx_state)
                    0: begin
                        lk_data <= 8'd0;
                        tx_stp  <= 1'b0;
                        if (tx_pending) begin
                            lk_data  <= 8'h43;                // TXCMD, PID DATA0
                            tx_state = 1;
                        end
                    end
                    1: if (ulpi_nxt) begin
                        if (tx_n > 0) begin
                            tx_idx   = 0;
                            lk_data <= tx_by[0];
                            tx_state = 2;
                        end else begin
                            lk_data <= 8'd0;
                            tx_stp  <= 1'b1;
                            tx_state = 3;
                        end
                    end
                    2: if (ulpi_nxt) begin
                        tx_idx = tx_idx + 1;
                        if (tx_idx == tx_n) begin
                            lk_data <= 8'd0;
                            tx_stp  <= 1'b1;
                            tx_state = 3;
                        end else begin
                            lk_data <= tx_by[tx_idx];
                        end
                    end
                    default: begin
                        tx_stp     <= 1'b0;
                        lk_data    <= 8'd0;
                        tx_state   = 0;
                        tx_pending = 1'b0;
                        tx_packets = tx_packets + 1;
                    end
                endcase
            end
        end
    end

    // ---------------- status changes ----------------
    reg        noise_en = 1'b0;
    reg [31:0] nr;
    always @(negedge clk_bit) begin
        if (noise_en && ce60) begin
            nr = $random(seed);
            if (nr[5:0] == 6'd0) begin
                case (nr[10:8] % 5)
                    0: linestate <= nr[13:12];
                    1: vbusstate <= nr[15:14];
                    2: host_disc <= nr[16];
                    3: id_gnd    <= nr[17];
                    default: alt_int <= nr[18];
                endcase
            end
        end
    end

    task set_status(input [1:0] ls, input [1:0] vb, input hd, input idg, input alt);
        begin
            @(negedge clk_bit);
            linestate = ls;
            vbusstate = vb;
            host_disc = hd;
            id_gnd    = idg;
            alt_int   = alt;
        end
    endtask

    task wait_ticks(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk_bit);
                while (!ce60) @(posedge clk_bit);
            end
            @(negedge clk_bit);
        end
    endtask

    // ---------------- pin monitor ----------------
    reg [7:0] log_b [0:16383];
    reg       log_d [0:16383];
    integer   log_n = 0;
    integer   pin_n = 0;
    integer   rxcmd_cnt = 0;

    reg       active   = 1'b0;
    integer   cur_n    = 0;
    reg [7:0] cur_b [0:255];
    reg       err_seen = 1'b0;
    reg       ab_fired = 1'b0;
    reg [1:0] exp_ev;
    reg [7:0] exp_cmd;
    integer   ci, cs;
    reg       cmism;

    always @(posedge clk_bit) begin
        if (rst_n && ce60) begin
            if (rx_overrun) begin
                errors = errors + 1;
                $display("ERROR @%0t: rx_overrun (second rx_start before the packet was closed)", $time);
            end
            if (tx_underrun) begin
                errors = errors + 1;
                $display("ERROR @%0t: tx_underrun", $time);
            end

            // bytes handed to the bus owner (pre-edge values)
            if (dut.arb_valid && dut.arb_ready) begin
                log_b[log_n] = dut.arb_data;
                log_d[log_n] = dut.arb_is_data;
                log_n = log_n + 1;
                if (!dut.arb_is_data) begin
                    exp_ev  = rx_active ? (rx_err ? 2'b11 : 2'b01) : (host_disc ? 2'b10 : 2'b00);
                    exp_cmd = {alt_int, id_gnd, exp_ev, vbusstate, linestate};
                    if (dut.arb_data !== exp_cmd) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: RXCMD = %02h, expected %02h", $time, dut.arb_data, exp_cmd);
                    end
                end
            end

            // pins as the Link sees them
            if (ulpi_data_oe && !ulpi_dir) begin
                errors = errors + 1;
                $display("ERROR @%0t: ulpi_data_oe without DIR", $time);
            end
            if (ulpi_dir && !ulpi_data_oe && ulpi_nxt) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT high in an undriven DIR tick", $time);
            end
            if (ulpi_data_oe) begin
                if (pin_n >= log_n) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: byte %02h on the pins that nobody handed over", $time, ulpi_data_out);
                end else begin
                    if ((ulpi_data_out !== log_b[pin_n]) || (ulpi_nxt !== log_d[pin_n])) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: pin byte %0d = %02h NXT=%b, expected %02h NXT=%b",
                                 $time, pin_n, ulpi_data_out, ulpi_nxt, log_b[pin_n], log_d[pin_n]);
                    end
                    pin_n = pin_n + 1;
                end

                if (ulpi_nxt) begin                           // RX data byte
                    if (!active) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: data byte while RxActive = 0", $time);
                    end else begin
                        cur_b[cur_n] = ulpi_data_out;
                        cur_n = cur_n + 1;
                    end
                end else begin                                // RXCMD
                    rxcmd_cnt = rxcmd_cnt + 1;
                    if (ulpi_data_out[4] && !active) begin    // RxActive rises
                        active   = 1'b1;
                        cur_n    = 0;
                        err_seen = 1'b0;
                        ab_fired = 1'b0;
                    end else if (!ulpi_data_out[4] && active) begin   // RxActive falls: packet closed
                        active = 1'b0;
                        cs     = pk_chk % 128;
                        if (pk_chk >= pk_n) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: an RX packet that was never queued", $time);
                        end else begin
                            if (!pk_loss[cs] && (cur_n != pk_len[cs])) begin
                                errors = errors + 1;
                                $display("ERROR @%0t: packet %0d: %0d bytes received, %0d sent", $time, pk_chk, cur_n, pk_len[cs]);
                            end
                            if (pk_loss[cs] && (cur_n > pk_len[cs])) begin
                                errors = errors + 1;
                                $display("ERROR @%0t: packet %0d: more bytes than sent", $time, pk_chk);
                            end
                            if ((pk_ab[cs] > 0) && (cur_n >= pk_len[cs])) begin
                                errors = errors + 1;
                                $display("ERROR @%0t: packet %0d: Link abort had no effect", $time, pk_chk);
                            end
                            cmism = 1'b0;
                            for (ci = 0; ci < cur_n; ci = ci + 1) begin
                                if (!cmism && (ci < pk_len[cs]) && (cur_b[ci] !== pk_data[cs * 64 + ci])) begin
                                    cmism  = 1'b1;
                                    errors = errors + 1;
                                    $display("ERROR @%0t: packet %0d byte %0d = %02h, expected %02h",
                                             $time, pk_chk, ci, cur_b[ci], pk_data[cs * 64 + ci]);
                                end
                            end
                            if (pk_experr[cs] && !err_seen) begin
                                errors = errors + 1;
                                $display("ERROR @%0t: packet %0d: RxError was not reported", $time, pk_chk);
                            end
                            if (!pk_experr[cs] && !pk_loss[cs] && err_seen) begin
                                errors = errors + 1;
                                $display("ERROR @%0t: packet %0d: unexpected RxError", $time, pk_chk);
                            end
                        end
                        pk_chk = pk_chk + 1;
                    end
                    if (active && (ulpi_data_out[5:4] == 2'b11)) err_seen = 1'b1;
                end
            end

            // DIR and the bus must stay driven inside a packet
            if (active && (!ulpi_dir || !ulpi_data_oe)) begin
                errors = errors + 1;
                $display("ERROR @%0t: DIR / bus not driven inside an RX packet", $time);
            end

            // Link abort: STP for one tick after the requested number of delivered bytes
            ab_stp <= (!ab_fired && active && (pk_chk < pk_n) && (pk_ab[pk_chk % 128] > 0)
                       && (cur_n == pk_ab[pk_chk % 128]));
            if (!ab_fired && active && (pk_chk < pk_n) && (pk_ab[pk_chk % 128] > 0)
                && (cur_n == pk_ab[pk_chk % 128]))
                ab_fired = 1'b1;
        end
    end

    task finish_rx;
        begin
            while (!((pk_chk == pk_n) && (pk_i == pk_n) && (rs_state == 0))) @(posedge clk_bit);
            wait_ticks(60);
        end
    endtask

    // ---------------- stimulus ----------------
    integer p, g, n, base_cnt, tmp_tick;
    reg [31:0] rr;

    task baseline;
        begin
            ie_rise = 5'h1F;
            ie_fall = 5'h1F;
            set_status(2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
            wait_ticks(80);
        end
    endtask

    task gate_case(input [255:0] name, input [4:0] ier, input [4:0] ief, input integer exp_cnt,
                   input [1:0] ls1, input [1:0] vb1, input hd1, input idg1, input alt1,
                   input second, input [1:0] ls2, input [1:0] vb2, input hd2, input idg2, input alt2);
        begin
            baseline;
            ie_rise  = ier;
            ie_fall  = ief;
            base_cnt = rxcmd_cnt;
            set_status(ls1, vb1, hd1, idg1, alt1);
            wait_ticks(40);
            if (second) begin
                set_status(ls2, vb2, hd2, idg2, alt2);
                wait_ticks(40);
            end
            if ((rxcmd_cnt - base_cnt) != exp_cnt) begin
                errors = errors + 1;
                $display("ERROR: gating case '%0s': %0d RXCMD(s), expected %0d", name, rxcmd_cnt - base_cnt, exp_cnt);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_usb_ulpi_phy_if.vcd");
        $dumpvars(0, tb_usb_ulpi_phy_if);

        rst_n = 1'b0;
        repeat (5) @(posedge clk_bit);
        @(negedge clk_bit) rst_n = 1'b1;
        repeat (10) @(posedge clk_bit);

        // ---------------- HS packets ----------------
        $display("HS packets (one byte per tick)");
        for (p = 0; p < 20; p = p + 1) q_pkt(1 + ({$random(seed)} % 40), 1, -1, 0, 1'b0, 1'b0);
        finish_rx;

        // ---------------- FS packets ----------------
        $display("FS packets (one byte per 40 ticks, DIR stays high, RXCMD filler)");
        for (p = 0; p < 5; p = p + 1) q_pkt(1 + ({$random(seed)} % 6), 40, -1, 0, 1'b0, 1'b0);
        finish_rx;

        // ---------------- mixed spacing with status noise and random masks ----------------
        $display("Mixed spacing, status changes during packets, random interrupt masks");
        noise_en = 1'b1;
        for (g = 0; g < 6; g = g + 1) begin
            rr      = $random(seed);
            ie_rise = rr[4:0];
            ie_fall = rr[12:8];
            for (p = 0; p < 4; p = p + 1) begin
                rr = $random(seed);
                case (rr[2:0] % 5)
                    0: n = 1;
                    1: n = 2;
                    2: n = 5;
                    3: n = 40;
                    default: n = 1;
                endcase
                q_pkt(1 + ({$random(seed)} % 20), n, -1, 0, 1'b0, 1'b0);
            end
            finish_rx;
        end
        noise_en = 1'b0;
        wait_ticks(40);

        // ---------------- RxError ----------------
        $display("Packets with RxError");
        for (p = 0; p < 6; p = p + 1) begin
            n = 3 + ({$random(seed)} % 28);
            q_pkt(n, 1, {$random(seed)} % n, 0, 1'b0, 1'b1);
        end
        for (p = 0; p < 2; p = p + 1) q_pkt(4, 40, 2, 0, 1'b0, 1'b1);
        finish_rx;

        // ---------------- Link abort ----------------
        $display("Link abort (STP while DIR = 1)");
        for (p = 0; p < 6; p = p + 1) q_pkt(12 + ({$random(seed)} % 28), 1, -1, 2 + ({$random(seed)} % 5), 1'b1, 1'b0);
        finish_rx;

        // ---------------- interrupt-mask gating ----------------
        $display("Interrupt-mask gating");
        gate_case("LineState always",             5'd0, 5'd0,      1, 2'd1, 2'd0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("VbusState, nothing enabled",   5'd0, 5'd0,      0, 2'd0, 2'd1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("SessEnd falling enabled",      5'd0, 5'b01000,  1, 2'd0, 2'd1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("SessEnd falling not enabled",  5'b01000, 5'd0,  0, 2'd0, 2'd1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("SessValid rising enabled",     5'b00100, 5'b01000, 2, 2'd0, 2'd1, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0, 2'd2, 1'b0, 1'b0, 1'b0);
        gate_case("VbusValid rising enabled",     5'b00010, 5'd0,  1, 2'd0, 2'd2, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0, 2'd3, 1'b0, 1'b0, 1'b0);
        gate_case("VbusValid falling not enabled",5'b00010, 5'd0,  1, 2'd0, 2'd3, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0, 2'd2, 1'b0, 1'b0, 1'b0);
        gate_case("HostDisconnect rise enabled",  5'b00001, 5'd0,  1, 2'd0, 2'd0, 1'b1, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("HostDisconnect rise masked",   5'd0, 5'b00001,  0, 2'd0, 2'd0, 1'b1, 1'b0, 1'b0, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("IdGnd rise masked, fall on",   5'd0, 5'b10000,  0, 2'd0, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("IdGnd rise and fall enabled",  5'b10000, 5'b10000, 2, 2'd0, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        gate_case("ALT_INT always",               5'd0, 5'd0,      1, 2'd0, 2'd0, 1'b0, 1'b0, 1'b1, 1'b0, 2'd0, 2'd0, 1'b0, 1'b0, 1'b0);
        baseline;

        // ---------------- FIFO overflow: the bus is busy with a TX packet ----------------
        $display("Overflow: RX packet arrives while a TX packet keeps the bus");
        for (p = 0; p < 40; p = p + 1) tx_by[p] = 8'h10 + p;
        tx_n       = 40;
        tx_pending = 1'b1;                                    // TXCMD + 40 bytes at HS speed
        while (!dut.u_core.hold_busy) @(posedge clk_bit);
        wait_ticks(4);
        rs_gap = 0;
        q_pkt(30, 1, -1, 0, 1'b1, 1'b1);                      // loses bytes, RxError must be reported
        finish_rx;
        while (tx_pending) @(posedge clk_bit);
        wait_ticks(80);

        // ---------------- final checks ----------------
        if (pk_chk != pk_n) begin
            errors = errors + 1;
            $display("ERROR: %0d RX packets queued, %0d closed", pk_n, pk_chk);
        end
        if (pin_n != log_n) begin
            errors = errors + 1;
            $display("ERROR: %0d bytes handed to the bus owner, %0d seen on the pins", log_n, pin_n);
        end
        if (ulpi_dir !== 1'b0 || ulpi_nxt !== 1'b0 || rx_active !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not idle at the end");
        end

        $display("--------------------------------------------------");
        $display("RX packets: %0d, RXCMD bytes: %0d, TX packets (overflow test): %0d", pk_chk, rxcmd_cnt, tx_packets);
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
