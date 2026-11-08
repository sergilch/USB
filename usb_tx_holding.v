//-----------------------------------------------------------------------------
// usb_tx_holding.v   (revision 2: latency-aware, 4-byte holding FIFO)
//
// "TX Holding Reg / Ctrl - TXCMD payload, NXT pacing" of the USB 2.0 PHY TX path.
//
//   ULPI pins -> usb_ulpi_input_capture -> [THIS BLOCK] -> SYNC + PID/Data Mux -> ...
//                                              |
//                                              +--> nxt_n --> NXT register in usb_ulpi_bus_owner
//
// What it does
//   * Takes a transmit TXCMD (decoded by usb_ulpi_input_capture: cmd_tx, cmd_pid;
//     PID 0 = NOPID) once it has been acknowledged with NXT.
//   * Takes the payload bytes that follow, buffers them in a 4-byte holding FIFO and
//     paces the Link with NXT so the FIFO never overflows.
//   * Terminates the packet on STP.  STP arrives one tick after the last byte, so the
//     last payload byte can only be marked "last" if it is held back until STP (or a
//     successor byte) is known: the head byte is released when a second byte is behind
//     it, or when STP has been seen.
//
// Why revision 2: the Link signals reach this block through the input capture
//   register, i.e. ONE TICK AFTER they were on the pins, while NXT is a registered
//   output that the Link sees in the tick it is on the pin.  So
//     * a byte consumed by NXT on the pin in tick t is captured in tick t+1:
//       nxt_seen (NXT delayed by one tick) qualifies the captured byte;
//     * one byte is always "in flight" (consumed on the pin, not yet in the FIFO):
//       nxt_pin (the NXT on the pin in the current tick) is counted in the credit,
//       which is why the FIFO has 4 entries (2 for the lookahead + 1 streaming +
//       1 in flight);
//     * NXT is withdrawn one tick early when STP is on the pin (stp_raw, the
//       unregistered STP), so NXT is low in the tick after STP.
//
// ULPI timing model (ticks = clock cycles with ce = 1):
//   * TXCMD stays on the bus until NXT = 1; NXT = 1 in a tick consumes the byte on
//     the bus in that tick (TXCMD first, then payload).  STP comes in the tick after
//     the last consumed byte; the DATA value in the STP tick is ignored.
//   * NXT may still be high in the STP tick itself (it was decided one tick earlier).
//   * A new TXCMD is acknowledged only after the previous packet has been completely
//     handed over to the next block; the Link simply waits for NXT.
//
// Outputs to the SYNC + PID/Data Mux:
//   * header (hdr_valid / hdr_ready, pid, nopid, hdr_empty): issued once the first
//     payload byte is buffered or STP has been seen, so hdr_empty (ACK / NAK / STALL
//     style packets without payload) is known;
//   * payload stream (d_valid / d_ready / d_data / d_last), after the header.
//
// With hdr_ready = d_ready = 1 the Link is paced at one byte per tick.
//
// Not handled here: register read/write TXCMDs (Register Access FSM) and aborting a
//   packet when the PHY takes the bus (the bus owner never takes the bus while this
//   block is busy).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_tx_holding (
    input  wire        clk,
    input  wire        rst_n,         // async assert, sync release
    input  wire        ce,            // tick enable (1 on clk60, ce60 on clk_bit)

    // ---- from usb_ulpi_input_capture (all aligned to the captured byte) ----
    input  wire        cmd_tx,        // captured byte is a transmit TXCMD (01 00 PPPP)
    input  wire [3:0]  cmd_pid,       // PPPP, 0 = NOPID
    input  wire        lnk_valid,     // captured byte was driven by the Link
    input  wire [7:0]  lnk_data,      // captured DATA
    input  wire        lnk_stp,       // captured STP (qualified)
    input  wire        nxt_seen,      // NXT on the pin in the tick of the captured byte
    input  wire        nxt_pin,       // NXT on the pin in the current tick
    input  wire        stp_raw,       // unregistered STP on the pin in the current tick

    // ---- NXT request toward the bus owner (next-state value, registered there) ----
    output wire        nxt_n,

    // ---- header to SYNC + PID/Data Mux ----
    output wire        hdr_valid,
    input  wire        hdr_ready,
    output wire [3:0]  hdr_pid,
    output wire        hdr_nopid,
    output wire        hdr_empty,     // no payload bytes in this packet

    // ---- payload stream to SYNC + PID/Data Mux ----
    output wire        d_valid,
    input  wire        d_ready,
    output wire [7:0]  d_data,
    output wire        d_last,

    output wire        busy
);

    localparam [1:0] ST_IDLE  = 2'd0;   // waiting for a TXCMD
    localparam [1:0] ST_ACT   = 2'd1;   // TXCMD taken, receiving payload
    localparam [1:0] ST_DRAIN = 2'd2;   // STP seen, flushing the FIFO downstream

    reg [1:0] st;
    reg [7:0] buf0, buf1, buf2, buf3;   // holding FIFO, buf0 = head
    reg [2:0] cnt;                      // bytes in the FIFO (0..4)
    reg       h_pending;                // header not yet handed over
    reg [3:0] h_pid;
    reg       h_nopid;

    // ---------------- input decoding ----------------
    wire take_cmd  = ce && (st == ST_IDLE) && nxt_seen && cmd_tx;
    wire take_byte = ce && (st == ST_ACT)  && nxt_seen && lnk_valid && !lnk_stp;
    wire stp_evt   = ce && (st == ST_ACT)  && lnk_valid &&  lnk_stp;

    // ---------------- outputs ----------------
    assign hdr_valid = h_pending && ((cnt != 3'd0) || (st == ST_DRAIN));
    assign hdr_pid   = h_pid;
    assign hdr_nopid = h_nopid;
    assign hdr_empty = (cnt == 3'd0);

    // the head byte is released when a successor is buffered or STP was seen
    assign d_valid = !h_pending && ((cnt >= 3'd2) || ((st == ST_DRAIN) && (cnt >= 3'd1)));
    assign d_data  = buf0;
    assign d_last  = (st == ST_DRAIN) && (cnt == 3'd1);

    assign busy    = (st != ST_IDLE);

    wire hdr_xfer = ce && hdr_valid && hdr_ready;
    wire d_xfer   = ce && d_valid   && d_ready;

    // ---------------- next-state logic ----------------
    reg [7:0] b0, b1, b2, b3;
    reg [2:0] c;
    reg [1:0] st_n;
    reg       hp_n;
    reg       nxt_r;

    always @* begin
        // FIFO: drain first, then append
        b0 = buf0;
        b1 = buf1;
        b2 = buf2;
        b3 = buf3;
        c  = cnt;
        if (d_xfer) begin
            b0 = buf1;
            b1 = buf2;
            b2 = buf3;
            b3 = 8'h00;
            c  = cnt - 3'd1;
        end
        if (take_byte) begin
            case (c)
                3'd0:    b0 = lnk_data;
                3'd1:    b1 = lnk_data;
                3'd2:    b2 = lnk_data;
                3'd3:    b3 = lnk_data;
                default: ;                     // cannot happen: the NXT credit keeps cnt <= 3
            endcase
            c = c + 3'd1;
        end

        // state
        st_n = st;
        hp_n = h_pending;
        if (hdr_xfer)
            hp_n = 1'b0;
        case (st)
            ST_IDLE: begin
                if (take_cmd) begin
                    st_n = ST_ACT;
                    hp_n = 1'b1;
                end
            end
            ST_ACT: begin
                if (stp_evt)
                    st_n = ST_DRAIN;
            end
            ST_DRAIN: begin
                if ((c == 3'd0) && !hp_n)
                    st_n = ST_IDLE;
            end
            default: st_n = ST_IDLE;
        endcase

        // NXT for the next tick
        case (st_n)
            ST_IDLE: nxt_r = cmd_tx;                               // acknowledge a TXCMD held by the Link
            ST_ACT:  nxt_r = (({1'b0, c} + {3'b000, nxt_pin}) <= 4'd3) && !stp_raw;
            default: nxt_r = 1'b0;
        endcase
    end

    assign nxt_n = nxt_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            buf0      <= 8'd0;
            buf1      <= 8'd0;
            buf2      <= 8'd0;
            buf3      <= 8'd0;
            cnt       <= 3'd0;
            h_pending <= 1'b0;
            h_pid     <= 4'd0;
            h_nopid   <= 1'b0;
        end else if (ce) begin
            st        <= st_n;
            buf0      <= b0;
            buf1      <= b1;
            buf2      <= b2;
            buf3      <= b3;
            cnt       <= c;
            h_pending <= hp_n;
            if (take_cmd) begin
                h_pid   <= cmd_pid;
                h_nopid <= (cmd_pid == 4'd0);               // 40h = NOPID
            end
        end
    end

endmodule
