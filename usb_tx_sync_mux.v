//-----------------------------------------------------------------------------
// usb_tx_sync_mux.v
//
// "SYNC + PID/Data Mux" of the USB 2.0 PHY TX path (HS / FS / LS).  Position:
//
//   TX Holding -> [THIS BLOCK] -> Bit Stuffer -> NRZI Encoder -> Serializer
//
// Builds the byte stream of one packet in front of the bit stuffer:
//
//   SYNC   (unless sync_dis)  HS: 00h 00h 00h 80h (32 bits, 31 zeros then a 1)
//                             FS / LS (and XcvrSelect 11): 80h (8 bits)
//                             In data bits, before NRZI: the NRZI encoder turns
//                             the zeros into KJKJ... and the final 1 into the
//                             trailing K of the SYNC pattern (..KJKK).
//   PID    (unless NOPID)     {~PID[3:0], PID[3:0]}, PID from the TXCMD (41h-4Fh)
//   DATA                      payload bytes from the holding block, unchanged.
//                             With NOPID the Link sends the PID itself as the
//                             first payload byte.
//
// The last byte of the stream is marked with out_last.  It is the last payload
// byte, or the PID byte when the packet has no payload (hdr_empty), or the last
// SYNC byte for a NOPID packet without payload.  A NOPID packet without payload
// with SYNC disabled has no bytes at all: the header is consumed and nothing is
// sent (the bit stuffer cannot carry an empty packet).
//
// Interface
//   Header  (hdr_valid / hdr_ready, hdr_pid, hdr_nopid, hdr_empty) from
//           usb_tx_holding, one per packet.  hdr_empty must be valid while
//           hdr_valid is high (usb_tx_holding issues the header only once the
//           first payload byte is buffered or STP was seen).
//   Payload (d_valid / d_ready, d_data, d_last), after the header.  d_ready is
//           only high in the DATA state, so bytes of the next packet are never
//           taken early.
//   Output  (out_valid / out_ready, out_data, out_last) to usb_bit_stuffer.
//           out_* depend combinationally on the state and, in the DATA state,
//           on d_*; out_ready goes straight to d_ready.  usb_bit_stuffer.in_ready
//           depends on registers only, so there is no combinational loop.
//   speed   XcvrSelect (00 HS, 01 FS, 10 LS, 11 = FS SYNC), sampled when the
//           header is taken.
//   sync_dis: 1 = do not send SYNC (chirp / raw patterns together with
//           bypass_en in the TX path).  Sampled when the header is taken.
//
// Throughput: with out_ready = 1 and the payload available, one byte per ce
//   tick from the first SYNC byte to the last byte, without gaps (required for
//   the gapless HS serializer behind the stuffer).  Taking the header costs one
//   tick before the first output byte.
//
// Clocking: one clock `clk` with a clock enable `ce`; all state changes and all
//   handshakes happen only on edges with ce = 1 (clk_bit with ce = ce60 in the
//   PHY, or clk60 with ce = 1).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_tx_sync_mux (
    input  wire        clk,
    input  wire        rst_n,        // async assert, sync release
    input  wire        ce,           // clock enable (tick)

    input  wire [1:0]  speed,        // XcvrSelect
    input  wire        sync_dis,     // 1 = no SYNC

    // ---- header from usb_tx_holding ----
    input  wire        hdr_valid,
    output wire        hdr_ready,
    input  wire [3:0]  hdr_pid,
    input  wire        hdr_nopid,
    input  wire        hdr_empty,

    // ---- payload from usb_tx_holding ----
    input  wire        d_valid,
    output wire        d_ready,
    input  wire [7:0]  d_data,
    input  wire        d_last,

    // ---- byte stream to usb_bit_stuffer ----
    output wire        out_valid,
    input  wire        out_ready,
    output wire [7:0]  out_data,
    output wire        out_last,

    output wire        busy
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SYNC = 2'd1;
    localparam [1:0] ST_PID  = 2'd2;
    localparam [1:0] ST_DATA = 2'd3;

    reg [1:0] st;
    reg [1:0] sync_left;     // SYNC bytes still to send after the current one
    reg [3:0] pid_q;
    reg       nopid_q;
    reg       empty_q;

    // ---------------- outputs ----------------
    wire sync_end = (sync_left == 2'd0);     // current SYNC byte is the last one

    assign hdr_ready = (st == ST_IDLE);
    assign d_ready   = (st == ST_DATA) && out_ready;

    assign out_valid = (st == ST_SYNC) || (st == ST_PID) || ((st == ST_DATA) && d_valid);

    assign out_data  = (st == ST_SYNC) ? (sync_end ? 8'h80 : 8'h00) :
                       (st == ST_PID)  ? {~pid_q, pid_q} :
                                         d_data;

    assign out_last  = (st == ST_SYNC) ? (sync_end && nopid_q && empty_q) :
                       (st == ST_PID)  ? empty_q :
                       (st == ST_DATA) ? d_last :
                                         1'b0;

    assign busy      = (st != ST_IDLE);

    wire hdr_xfer = ce && hdr_valid && hdr_ready;
    wire out_xfer = ce && out_valid && out_ready;

    // state that follows SYNC (or the header, when SYNC is disabled)
    function [1:0] after_sync;
        input nopid;
        input empty;
        begin
            if (!nopid)     after_sync = ST_PID;
            else if (!empty) after_sync = ST_DATA;
            else             after_sync = ST_IDLE;   // nothing (more) to send
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            sync_left <= 2'd0;
            pid_q     <= 4'd0;
            nopid_q   <= 1'b0;
            empty_q   <= 1'b0;
        end else begin
            case (st)
                ST_IDLE: begin
                    if (hdr_xfer) begin
                        pid_q     <= hdr_pid;
                        nopid_q   <= hdr_nopid;
                        empty_q   <= hdr_empty;
                        sync_left <= (speed == 2'b00) ? 2'd3 : 2'd0;
                        st        <= sync_dis ? after_sync(hdr_nopid, hdr_empty) : ST_SYNC;
                    end
                end

                ST_SYNC: begin
                    if (out_xfer) begin
                        if (sync_end) st <= after_sync(nopid_q, empty_q);
                        else          sync_left <= sync_left - 2'd1;
                    end
                end

                ST_PID: begin
                    if (out_xfer)
                        st <= empty_q ? ST_IDLE : ST_DATA;
                end

                ST_DATA: begin
                    if (out_xfer && d_last)
                        st <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
