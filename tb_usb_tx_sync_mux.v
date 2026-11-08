//-----------------------------------------------------------------------------
// tb_usb_tx_sync_mux.v - self-checking testbench for usb_tx_sync_mux
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_mux usb_tx_sync_mux.v tb_usb_tx_sync_mux.v
//   vvp sim_mux
//
// A header/payload source (behaves like usb_tx_holding: one header per packet,
// payload bytes after the header, every item held until it is taken) feeds the
// DUT; a sink with optional random back-pressure takes the output.  Checked:
//   * the output byte stream against a reference built from the packet list:
//     SYNC (HS 00 00 00 80, FS/LS/11 80, none with sync_dis), PID {~pid, pid}
//     (not for NOPID), payload; out_last exactly on the last byte;
//   * packets with no bytes at all (NOPID, no payload, sync_dis): the header is
//     consumed and nothing is sent;
//   * speed / sync_dis are sampled with the header (they are changed randomly
//     while the packet is being sent);
//   * out_valid / out_data / out_last stable while out_valid && !out_ready;
//   * d_ready only in the payload phase (never before the header was taken);
//   * gapless output (one byte per ce tick from the first to the last byte) when
//     the payload is always available and the sink never stalls;
//   * busy low after every run;
//   * ce: state changes and transfers only on ce ticks (run with ce = 1 in 8
//     and ce = 1 always).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_tx_sync_mux;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg       rst_n;
    reg [2:0] ce_cnt;
    reg       ce_every = 1'b0;               // 1: ce in every cycle
    wire      ce = ce_every || (ce_cnt == 3'd7);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ce_cnt <= 3'd0;
        else        ce_cnt <= ce_cnt + 3'd1;
    end

    // ---------------- DUT ----------------
    reg  [1:0] speed    = 2'b00;
    reg        sync_dis = 1'b0;
    reg        hdr_valid = 1'b0;
    reg  [3:0] hdr_pid   = 4'd0;
    reg        hdr_nopid = 1'b0;
    reg        hdr_empty = 1'b0;
    wire       hdr_ready;
    reg        d_valid = 1'b0;
    reg  [7:0] d_data  = 8'd0;
    reg        d_last  = 1'b0;
    wire       d_ready;
    wire       out_valid, out_last, busy;
    wire [7:0] out_data;
    reg        out_ready = 1'b1;

    usb_tx_sync_mux dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .speed     (speed),
        .sync_dis  (sync_dis),
        .hdr_valid (hdr_valid),
        .hdr_ready (hdr_ready),
        .hdr_pid   (hdr_pid),
        .hdr_nopid (hdr_nopid),
        .hdr_empty (hdr_empty),
        .d_valid   (d_valid),
        .d_ready   (d_ready),
        .d_data    (d_data),
        .d_last    (d_last),
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (out_data),
        .out_last  (out_last),
        .busy      (busy)
    );

    integer errors = 0;
    integer seed   = 32'h5A17_C0DE;

    // ---------------- packet list (source side) ----------------
    reg [3:0] p_pid   [0:2047];
    reg       p_nopid [0:2047];
    reg [1:0] p_spd   [0:2047];
    reg       p_sdis  [0:2047];
    integer   p_n     [0:2047];
    reg [7:0] p_pay   [0:65535];             // 2048 packets x 32 bytes
    integer   p_tail = 0;                    // packets queued

    // ---------------- expected output stream ----------------
    reg [7:0] e_byte [0:131071];
    reg       e_last [0:131071];
    integer   e_tail = 0;
    integer   e_head = 0;

    // ---------------- mode ----------------
    reg       src_gaps  = 1'b0;              // random gaps before items
    reg       sink_stall = 1'b0;             // random out_ready = 0
    reg       cfg_noise = 1'b1;              // change speed / sync_dis after the header

    task queue_packet(input [3:0] pid, input nopid, input [1:0] spd, input sdis, input integer nb);
        integer i;
        reg [7:0] b;
        begin
            p_pid[p_tail]   = pid;
            p_nopid[p_tail] = nopid;
            p_spd[p_tail]   = spd;
            p_sdis[p_tail]  = sdis;
            p_n[p_tail]     = nb;
            for (i = 0; i < nb; i = i + 1) begin
                b = $random(seed);
                p_pay[p_tail * 32 + i] = b;
            end
            // reference stream
            if (!sdis) begin
                if (spd == 2'b00) begin
                    e_byte[e_tail] = 8'h00; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
                    e_byte[e_tail] = 8'h00; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
                    e_byte[e_tail] = 8'h00; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
                end
                e_byte[e_tail] = 8'h80; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
            end
            if (!nopid) begin
                e_byte[e_tail] = {~pid, pid}; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
            end
            for (i = 0; i < nb; i = i + 1) begin
                e_byte[e_tail] = p_pay[p_tail * 32 + i]; e_last[e_tail] = 1'b0; e_tail = e_tail + 1;
            end
            if (e_tail > 0 && (!sdis || !nopid || nb > 0))
                e_last[e_tail - 1] = 1'b1;
            p_tail = p_tail + 1;
        end
    endtask

    // ---------------- source model (acts on ce ticks) ----------------
    integer s_pkt   = 0;                     // packet being sent
    integer s_state = 0;                     // 0 gap, 1 header, 2 payload gap, 3 payload byte
    integer s_idx   = 0;
    integer s_gap   = 0;
    integer hdrs_taken = 0;

    task do_source;
        begin
            case (s_state)
                0: begin
                    if (s_pkt < p_tail) begin
                        if (s_gap > 0) s_gap = s_gap - 1;
                        else begin
                            hdr_valid <= 1'b1;
                            hdr_pid   <= p_pid[s_pkt];
                            hdr_nopid <= p_nopid[s_pkt];
                            hdr_empty <= (p_n[s_pkt] == 0);
                            speed     <= p_spd[s_pkt];
                            sync_dis  <= p_sdis[s_pkt];
                            s_state   = 1;
                        end
                    end
                end
                1: begin
                    if (hdr_valid && hdr_ready) begin
                        hdrs_taken = hdrs_taken + 1;
                        hdr_valid <= 1'b0;
                        if (cfg_noise) begin        // DUT must have sampled the config
                            speed    <= $random(seed);
                            sync_dis <= $random(seed);
                        end
                        s_idx = 0;
                        if (p_n[s_pkt] == 0) begin
                            s_pkt   = s_pkt + 1;
                            s_gap   = src_gaps ? ({$random(seed)} % 4) : 0;
                            s_state = 0;
                        end else begin
                            s_gap   = src_gaps ? ({$random(seed)} % 3) : 0;
                            s_state = 2;
                        end
                    end
                end
                default: ;
            endcase

            // payload: present a byte, hold it until it is taken
            if (s_state == 3 && d_valid && d_ready) begin
                d_valid <= 1'b0;
                s_idx   = s_idx + 1;
                if (s_idx == p_n[s_pkt]) begin
                    s_pkt   = s_pkt + 1;
                    s_gap   = src_gaps ? ({$random(seed)} % 4) : 0;
                    s_state = 0;
                end else begin
                    s_gap   = src_gaps ? ({$random(seed)} % 3) : 0;
                    s_state = 2;
                end
            end
            if (s_state == 2) begin
                if (s_gap > 0) s_gap = s_gap - 1;
                else begin
                    d_valid <= 1'b1;
                    d_data  <= p_pay[s_pkt * 32 + s_idx];
                    d_last  <= (s_idx == p_n[s_pkt] - 1);
                    s_state = 3;
                end
            end
        end
    endtask

    // ---------------- sink / checker ----------------
    reg       stall_q = 1'b0;                // last ce tick: valid && !ready
    reg [7:0] stall_data;
    reg       stall_last;
    reg       in_pkt  = 1'b0;                // inside an output packet
    integer   bytes_seen = 0;

    task do_check;
        begin
                if (d_ready && !(hdrs_taken > s_pkt)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: d_ready before the header of the packet was taken", $time);
                end

                // stability under back-pressure
                if (stall_q) begin
                    if (!out_valid || (out_data !== stall_data) || (out_last !== stall_last)) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: output changed while stalled", $time);
                    end
                end
                stall_q    = out_valid && !out_ready;
                stall_data = out_data;
                stall_last = out_last;

                // gapless output when nothing stalls
                if (!src_gaps && !sink_stall && in_pkt && !out_valid) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: gap inside an output packet", $time);
                end

                if (out_valid && out_ready) begin
                    bytes_seen = bytes_seen + 1;
                    if (e_head >= e_tail) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: unexpected output byte %02h", $time, out_data);
                    end else begin
                        if ((out_data !== e_byte[e_head]) || (out_last !== e_last[e_head])) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: output %02h last=%b, expected %02h last=%b (byte %0d)",
                                     $time, out_data, out_last, e_byte[e_head], e_last[e_head], e_head);
                        end
                        e_head = e_head + 1;
                    end
                    in_pkt = !out_last;
                end

                out_ready <= sink_stall ? ({$random(seed)} % 3 != 0) : 1'b1;
        end
    endtask

    // one block: the checks see the source state of the same tick before it advances
    always @(posedge clk) begin
        if (rst_n && ce) begin
            do_check;
            do_source;
        end
    end

    // ---------------- helpers ----------------
    task finish_all;
        begin
            while (!((s_pkt == p_tail) && (s_state == 0) && (e_head == e_tail) && !busy))
                @(posedge clk);
            repeat (20) @(posedge clk);
            if (busy) begin
                errors = errors + 1;
                $display("ERROR @%0t: busy still high after the run", $time);
            end
        end
    endtask

    task random_run(input integer npk, input g, input st, input integer maxlen);
        integer i, nb;
        reg [31:0] r;
        begin
            src_gaps   = g;
            sink_stall = st;
            for (i = 0; i < npk; i = i + 1) begin
                r  = $random(seed);
                nb = (r[3:2] == 2'd0) ? 0 : ({$random(seed)} % (maxlen + 1));
                queue_packet(r[11:8], r[13:12] == 2'd0, r[15:14], r[17:16] == 2'd0, nb);
            end
            finish_all;
        end
    endtask

    // ---------------- stimulus ----------------
    integer pass;

    initial begin
        $dumpfile("tb_usb_tx_sync_mux.vcd");
        $dumpvars(0, tb_usb_tx_sync_mux);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (10) @(posedge clk);

        for (pass = 0; pass < 2; pass = pass + 1) begin
            ce_every = pass;
            $display("Pass %0d: ce %s", pass, pass ? "every cycle" : "1 in 8");

            $display("  directed");
            src_gaps = 1'b0; sink_stall = 1'b0;
            queue_packet(4'h2, 1'b0, 2'b00, 1'b0, 0);    // HS ACK: SYNC x4 + PID, last on PID
            queue_packet(4'h2, 1'b0, 2'b01, 1'b0, 0);    // FS ACK
            queue_packet(4'hD, 1'b0, 2'b10, 1'b0, 2);    // LS SETUP token
            queue_packet(4'h3, 1'b0, 2'b11, 1'b0, 3);    // XcvrSelect 11: FS SYNC
            queue_packet(4'h0, 1'b1, 2'b00, 1'b0, 0);    // NOPID, no payload: SYNC only
            queue_packet(4'h0, 1'b1, 2'b01, 1'b0, 0);
            queue_packet(4'h0, 1'b1, 2'b00, 1'b1, 0);    // nothing on the output at all
            queue_packet(4'h0, 1'b1, 2'b00, 1'b1, 0);
            queue_packet(4'h0, 1'b1, 2'b00, 1'b1, 1);    // one raw byte
            queue_packet(4'h5, 1'b0, 2'b00, 1'b1, 0);    // PID only
            queue_packet(4'hB, 1'b0, 2'b00, 1'b1, 5);
            queue_packet(4'h0, 1'b1, 2'b01, 1'b0, 4);    // NOPID with payload
            finish_all;

            $display("  random, no gaps, no stalls (gapless check)");
            random_run(150, 1'b0, 1'b0, 31);
            $display("  random, source gaps");
            random_run(150, 1'b1, 1'b0, 31);
            $display("  random, sink back-pressure");
            random_run(150, 1'b0, 1'b1, 31);
            $display("  random, gaps and back-pressure");
            random_run(150, 1'b1, 1'b1, 31);
        end

        repeat (20) @(posedge clk);
        if (hdrs_taken != p_tail) begin
            errors = errors + 1;
            $display("ERROR: %0d headers queued, %0d taken", p_tail, hdrs_taken);
        end
        $display("%0d packets, %0d output bytes checked", p_tail, bytes_seen);
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
