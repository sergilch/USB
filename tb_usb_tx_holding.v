//-----------------------------------------------------------------------------
// tb_usb_tx_holding.v - self-checking testbench for usb_tx_holding (revision 2)
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_hold usb_ulpi_input_capture.v usb_tx_holding.v tb_usb_tx_holding.v
//   vvp sim_hold
//
// DUT chain: Link pins -> usb_ulpi_input_capture -> usb_tx_holding.  The NXT pin
// register is modelled in the bench (nxt_q <= nxt_n), DIR is always low.  The
// pin-level ULPI Link TX model
//   * holds TXCMD on DATA until it sees NXT, consumes one byte per tick with NXT = 1,
//   * asserts STP in the tick after the last byte,
//   * acts only on ce ticks (ce = 1 on clk60 in a real design).
// The downstream side is a monitor with random backpressure.  Checked:
//   * header: pid / nopid / hdr_empty for every packet, issued before the payload;
//   * payload bytes, order and the d_last flag (only on the final byte);
//   * NXT only while the Link has a TXCMD on the bus or is inside a packet, and low
//     in the tick after STP (stp_raw withdrawal);
//   * no FIFO overflow;
//   * with no backpressure the Link is paced at one byte per tick;
//   * back-to-back packets, packets without payload (ACK-like) and NOPID packets.
//
//   ce_mode : 0 = always, 1 = one tick in eight (ce60 style), 2 = random 50 %
//   ro_mode : hdr_ready / d_ready  0 = always 1, 1 = random 50 %, 2 = random 25 %
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_tx_holding;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    reg ce = 1'b1;

    // ---------------- pins ----------------
    reg  [7:0] pin_data = 8'd0;        // driven by the Link model
    reg        pin_stp  = 1'b0;
    reg        nxt_q    = 1'b0;        // NXT pin register (bench model)
    wire       dir_q    = 1'b0;

    // ---------------- capture ----------------
    wire       lnk_valid, lnk_stp, nxt_seen, stp_raw;
    wire [7:0] lnk_data;
    wire       cmd_noop, cmd_tx, cmd_regw, cmd_regr, cmd_ext;
    wire [3:0] cmd_pid;
    wire [5:0] cmd_addr;

    usb_ulpi_input_capture cap (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .data_in   (pin_data),
        .stp_in    (pin_stp),
        .dir_q     (dir_q),
        .nxt_q     (nxt_q),
        .lnk_valid (lnk_valid),
        .lnk_data  (lnk_data),
        .lnk_stp   (lnk_stp),
        .nxt_seen  (nxt_seen),
        .stp_raw   (stp_raw),
        .cmd_noop  (cmd_noop),
        .cmd_tx    (cmd_tx),
        .cmd_pid   (cmd_pid),
        .cmd_regw  (cmd_regw),
        .cmd_regr  (cmd_regr),
        .cmd_ext   (cmd_ext),
        .cmd_addr  (cmd_addr)
    );

    // ---------------- DUT ----------------
    wire       nxt_n;
    wire       hdr_valid;
    reg        hdr_ready = 1'b1;
    wire [3:0] hdr_pid;
    wire       hdr_nopid, hdr_empty;
    wire       d_valid;
    reg        d_ready = 1'b1;
    wire [7:0] d_data;
    wire       d_last;
    wire       busy;

    usb_tx_holding dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .cmd_tx    (cmd_tx),
        .cmd_pid   (cmd_pid),
        .lnk_valid (lnk_valid),
        .lnk_data  (lnk_data),
        .lnk_stp   (lnk_stp),
        .nxt_seen  (nxt_seen),
        .nxt_pin   (nxt_q),
        .stp_raw   (stp_raw),
        .nxt_n     (nxt_n),
        .hdr_valid (hdr_valid),
        .hdr_ready (hdr_ready),
        .hdr_pid   (hdr_pid),
        .hdr_nopid (hdr_nopid),
        .hdr_empty (hdr_empty),
        .d_valid   (d_valid),
        .d_ready   (d_ready),
        .d_data    (d_data),
        .d_last    (d_last),
        .busy      (busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)  nxt_q <= 1'b0;
        else if (ce) nxt_q <= nxt_n;
    end

    // ---------------- modes ----------------
    integer ce_mode = 0;
    integer ro_mode = 0;
    integer ce_ph   = 0;
    integer seed_ce = 32'h0A0A_0A0A;
    integer seed_ro = 32'h0B0B_0B0B;
    integer seed    = 32'h0C0C_0C0C;
    integer tick    = 0;

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
            0: begin
                   hdr_ready <= 1'b1;
                   d_ready   <= 1'b1;
               end
            1: begin
                   hdr_ready <= (({$random(seed_ro)} % 2) == 1);
                   d_ready   <= (({$random(seed_ro)} % 2) == 1);
               end
            default: begin
                   hdr_ready <= (({$random(seed_ro)} % 4) == 0);
                   d_ready   <= (({$random(seed_ro)} % 4) == 0);
               end
        endcase
    end

    always @(posedge clk) if (ce) tick <= tick + 1;

    // ---------------- expected packets ----------------
    reg [3:0] q_pid   [0:127];
    reg       q_nopid [0:127];
    integer   q_n     [0:127];
    reg [7:0] q_data  [0:8191];          // 128 slots x 64 bytes
    integer   q_head = 0;
    integer   q_tail = 0;

    reg [7:0] src_bytes [0:63];

    integer errors       = 0;
    integer pkts_checked = 0;

    // ---------------- pin-level Link TX model ----------------
    reg     link_cmd_on_bus = 1'b0;
    reg     link_in_pkt     = 1'b0;
    reg     chk_tp          = 1'b0;
    integer prev_cons       = -1;
    integer cons_tick       = 0;

    // Byte already placed on pin_data; wait until NXT consumes it.
    // Called at a falling edge, returns at the falling edge after the consuming tick.
    task wait_consume;
        reg consumed;
        begin
            consumed = 1'b0;
            while (!consumed) begin
                @(posedge clk);
                if (ce && nxt_q) begin                 // pre-edge values
                    consumed  = 1'b1;
                    cons_tick = tick;
                end
            end
            if (chk_tp && (prev_cons >= 0) && ((cons_tick - prev_cons) != 1)) begin
                errors = errors + 1;
                $display("ERROR @%0t: Link was paced with a gap (%0d ticks between bytes)",
                         $time, cons_tick - prev_cons);
            end
            prev_cons = cons_tick;
            @(negedge clk);
        end
    endtask

    task wait_tick;                                   // wait for the next ce tick
        reg ok;
        begin
            ok = 1'b0;
            while (!ok) begin
                @(posedge clk);
                if (ce) ok = 1'b1;
            end
            @(negedge clk);
        end
    endtask

    task link_packet(input [3:0] pid, input nopid, input integer nb, input integer idle_ticks);
        integer i, qi, k;
        begin
            qi = q_tail % 128;
            q_pid[qi]   = pid;
            q_nopid[qi] = nopid;
            q_n[qi]     = nb;
            for (i = 0; i < nb; i = i + 1) q_data[qi * 64 + i] = src_bytes[i];
            q_tail = q_tail + 1;

            for (k = 0; k < idle_ticks; k = k + 1) wait_tick;

            // TXCMD
            pin_data        = nopid ? 8'h40 : {4'h4, pid};
            link_cmd_on_bus = 1'b1;
            prev_cons       = -1;
            wait_consume;
            link_cmd_on_bus = 1'b0;
            link_in_pkt     = 1'b1;

            // payload
            for (i = 0; i < nb; i = i + 1) begin
                pin_data = src_bytes[i];
                wait_consume;
            end

            // STP in the tick after the last byte, one tick long
            pin_data = 8'h00;
            pin_stp  = 1'b1;
            wait_tick;
            pin_stp     = 1'b0;
            link_in_pkt = 1'b0;
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

    // ---------------- monitor ----------------
    reg     rx_active = 1'b0;
    integer rx_idx    = 0;
    integer rx_qi     = 0;
    integer mq;

    always @(posedge clk) begin
        if (rst_n) begin
            if (nxt_q && !link_cmd_on_bus && !link_in_pkt) begin
                errors = errors + 1;
                $display("ERROR @%0t: spurious NXT", $time);
            end
            if (dut.take_byte && (dut.cnt == 3'd4)) begin
                errors = errors + 1;
                $display("ERROR @%0t: holding FIFO overflow", $time);
            end

            if (ce) begin
                if (d_valid && !rx_active) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: payload offered before the header was taken", $time);
                end

                if (hdr_valid && hdr_ready) begin
                    if (q_head == q_tail) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: header without an expected packet", $time);
                    end else begin
                        mq = q_head % 128;
                        if (hdr_nopid !== q_nopid[mq]) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: hdr_nopid = %b, expected %b", $time, hdr_nopid, q_nopid[mq]);
                        end else if (!q_nopid[mq] && (hdr_pid !== q_pid[mq])) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: hdr_pid = %h, expected %h", $time, hdr_pid, q_pid[mq]);
                        end
                        if (hdr_empty !== (q_n[mq] == 0)) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: hdr_empty = %b, payload bytes = %0d", $time, hdr_empty, q_n[mq]);
                        end
                        rx_qi     = mq;
                        rx_idx    = 0;
                        rx_active = (q_n[mq] != 0);
                        if (q_n[mq] == 0) begin
                            q_head       = q_head + 1;
                            pkts_checked = pkts_checked + 1;
                        end
                    end
                end

                if (d_valid && d_ready && rx_active) begin
                    if (d_data !== q_data[rx_qi * 64 + rx_idx]) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: payload byte %0d = %02h, expected %02h",
                                 $time, rx_idx, d_data, q_data[rx_qi * 64 + rx_idx]);
                    end
                    if (d_last !== (rx_idx == q_n[rx_qi] - 1)) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: d_last = %b at byte %0d of %0d",
                                 $time, d_last, rx_idx, q_n[rx_qi]);
                    end
                    rx_idx = rx_idx + 1;
                    if (rx_idx == q_n[rx_qi]) begin
                        rx_active    = 1'b0;
                        q_head       = q_head + 1;
                        pkts_checked = pkts_checked + 1;
                    end
                end
            end
        end
    end

    task finish_all;
        begin
            wait (pkts_checked == q_tail);
            repeat (6) @(posedge clk);
        end
    endtask

    // ---------------- stimulus ----------------
    integer cm, rm, p, nb, idle;
    reg [3:0] rpid;
    reg       rnop;
    reg [31:0] rr;

    initial begin
        $dumpfile("tb_usb_tx_holding.vcd");
        $dumpvars(0, tb_usb_tx_holding);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);

        // ---------------- directed, no backpressure ----------------
        ce_mode = 0;
        ro_mode = 0;
        chk_tp  = 1'b1;

        $display("D1: ACK-like packet (PID 2, no payload)");
        link_packet(4'h2, 1'b0, 0, 0);
        finish_all;

        $display("D2: NOPID without payload");
        link_packet(4'h0, 1'b1, 0, 0);
        finish_all;

        $display("D3: PID 3, 1 byte");
        fill(1);
        link_packet(4'h3, 1'b0, 1, 0);
        finish_all;

        $display("D4: PID 3, 2 bytes");
        fill(2);
        link_packet(4'h3, 1'b0, 2, 0);
        finish_all;

        $display("D5: PID 3, 3 bytes");
        fill(3);
        link_packet(4'h3, 1'b0, 3, 0);
        finish_all;

        $display("D6: PID D, 16 bytes (full-rate streaming)");
        fill(16);
        link_packet(4'hD, 1'b0, 16, 0);
        finish_all;

        $display("D7: NOPID, 5 bytes");
        fill(5);
        link_packet(4'h0, 1'b1, 5, 0);
        finish_all;

        $display("D8: three back-to-back packets");
        fill(4);  link_packet(4'h1, 1'b0, 4, 0);
        fill(0);  link_packet(4'h2, 1'b0, 0, 0);
        fill(7);  link_packet(4'hB, 1'b0, 7, 0);
        finish_all;
        chk_tp = 1'b0;

        // ---------------- random packets in all modes ----------------
        for (cm = 0; cm < 3; cm = cm + 1) begin
            for (rm = 0; rm < 3; rm = rm + 1) begin
                $display("R: ce_mode = %0d, ro_mode = %0d", cm, rm);
                ce_mode = cm;
                ro_mode = rm;
                for (p = 0; p < 30; p = p + 1) begin
                    nb   = {$random(seed)} % 25;                  // 0..24 bytes
                    rr   = $random(seed);
                    rnop = (rr[3:0] == 4'd0);
                    rpid = (rr[7:4] == 4'd0) ? 4'd1 : rr[7:4];
                    idle = {$random(seed)} % 5;
                    fill(nb);
                    link_packet(rpid, rnop, nb, idle);
                end
                finish_all;
            end
        end

        // ---------------- final checks ----------------
        repeat (20) @(posedge clk);
        if (pkts_checked != q_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d packets sent, %0d checked", q_tail, pkts_checked);
        end
        if (busy !== 1'b0 || nxt_q !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: DUT not idle at the end");
        end

        $display("--------------------------------------------------");
        $display("Packets checked: %0d", pkts_checked);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
