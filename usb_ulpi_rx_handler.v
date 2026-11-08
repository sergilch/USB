//-----------------------------------------------------------------------------
// usb_ulpi_rx_handler.v
//
// "RX Data Handler" of the ULPI Interface Controller (PHY side).
//
//   RX datapath (elastic buffer) --> [THIS BLOCK] --> usb_ulpi_out_arbiter --> bus owner --> Link
//                                        |  rxa / rxe  --> usb_ulpi_rxcmd_gen (RxEvent field)
//                                        |  sent_rxev  <-- usb_ulpi_rxcmd_gen (what the Link was told)
//
// ULPI has no flow control on receive: bytes arrive at the line rate (HS: one byte per
// tick) while the PHY first has to take the bus (turnaround) and send the RXCMD that
// announces RxActive.  This block therefore keeps the bytes of the packet in a small FIFO
// (DEPTH bytes) and keeps the framing:
//
//   rx_start  (pulse)  : a packet starts (SYNC detected).  rxa goes high; the RXCMD
//                        generator turns that into an RXCMD with RxActive = 1.
//   rx_valid / rx_data : one byte of the packet (any rate, FIFO write).
//   rx_error  (pulse)  : receive error (bit stuff / CRC-less framing error ...): rxe goes high
//                        (RxEvent = RxActive + RxError).
//   rx_end    (pulse)  : the packet is over (EOP detected), at or after the last byte.
//   rx_abort  (pulse)  : the Link asserted STP while the PHY owned the bus: the remaining
//                        bytes of the packet are thrown away and RxActive ends.
//
// Rules implemented
//   * Data is released to the arbiter only after an RXCMD with RxActive = 1 has gone out
//     (sent_rxev[0]); the arbiter keeps sending RXCMD bytes while rxa is high and no data
//     is available, so DIR stays high for the whole packet.
//   * RxActive ends (rxa low) only after the last byte was taken by the arbiter, and, if
//     RxError is set, only after an RXCMD with RxEvent = RxActive + RxError was sent, so
//     the error is never lost even when the data stream does not leave room for an RXCMD
//     (HS).  The next RXCMD then reports RxActive = 0.
//   * FIFO overflow (the bus could not be taken in time): the byte is dropped and RxError
//     is set.
//   * A new rx_start while the previous packet has not been closed yet is ignored and
//     reported on `overrun` (one tick); rx_start after rx_abort is accepted.
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_rx_handler #(
    parameter DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,          // async assert, sync release
    input  wire        ce,

    // from the RX datapath
    input  wire        rx_start,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_end,
    input  wire        rx_error,

    // Link abort (STP while DIR = 1), from usb_ulpi_input_capture
    input  wire        rx_abort,

    // RXCMD generator
    input  wire [1:0]  sent_rxev,      // RxEvent field of the last RXCMD that was sent
    output wire        rxa,            // RxActive
    output wire        rxe,            // RxError

    // toward the arbiter
    output wire        rxd_valid,
    output wire [7:0]  rxd_data,
    input  wire        rxd_ready,      // the byte is taken in this tick (includes ce)

    output reg         overrun
);

    localparam PW = (DEPTH <= 2) ? 1 : (DEPTH <= 4) ? 2 : (DEPTH <= 8) ? 3 : (DEPTH <= 16) ? 4 : 5;

    reg [7:0]    mem [0:DEPTH-1];
    reg [PW-1:0] rd_p, wr_p;
    reg [PW:0]   cnt;
    reg          act, err, endp, drop;

    assign rxa       = act;
    assign rxe       = err;
    assign rxd_valid = act && sent_rxev[0] && (cnt != 0);
    assign rxd_data  = mem[rd_p];

    // ---------------- next-state logic ----------------
    reg [PW:0]   cnt_n;
    reg [PW-1:0] rd_n, wr_n;
    reg          act_n, err_n, endp_n, drop_n;
    reg          push, ovr;

    always @* begin
        cnt_n  = cnt;
        rd_n   = rd_p;
        wr_n   = wr_p;
        act_n  = act;
        err_n  = err;
        endp_n = endp;
        drop_n = drop;
        push   = 1'b0;
        ovr    = 1'b0;

        if (rxd_ready) begin                           // the arbiter took the head byte
            rd_n  = (rd_p == DEPTH - 1) ? {PW{1'b0}} : rd_p + 1'b1;
            cnt_n = cnt - 1'b1;
        end

        if (rx_abort && act) begin                     // Link abort: drop everything
            cnt_n  = {(PW+1){1'b0}};
            rd_n   = wr_p;
            drop_n = 1'b1;
            act_n  = 1'b0;
            err_n  = 1'b0;
            endp_n = 1'b0;
        end

        if (rx_start) begin
            if (act_n) begin
                ovr = 1'b1;                            // previous packet not closed yet
            end else begin
                act_n  = 1'b1;
                err_n  = 1'b0;
                endp_n = 1'b0;
                drop_n = 1'b0;
            end
        end

        if (rx_valid && act_n && !drop_n) begin
            if (cnt_n >= DEPTH) begin
                err_n = 1'b1;                          // overflow: byte dropped
            end else begin
                push = 1'b1;
                wr_n = (wr_p == DEPTH - 1) ? {PW{1'b0}} : wr_p + 1'b1;
            end
        end

        if (rx_error && act_n && !drop_n)
            err_n = 1'b1;

        if (rx_end) begin
            if (act_n && !drop_n)
                endp_n = 1'b1;
            drop_n = 1'b0;
        end

        // close the packet when everything was delivered (and an error was reported)
        if (endp_n && ((cnt_n + (push ? 1'b1 : 1'b0)) == 0) && (!err_n || (sent_rxev == 2'b11))) begin
            act_n  = 1'b0;
            err_n  = 1'b0;
            endp_n = 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_p    <= {PW{1'b0}};
            wr_p    <= {PW{1'b0}};
            cnt     <= {(PW+1){1'b0}};
            act     <= 1'b0;
            err     <= 1'b0;
            endp    <= 1'b0;
            drop    <= 1'b0;
            overrun <= 1'b0;
        end else if (ce) begin
            rd_p    <= rd_n;
            wr_p    <= wr_n;
            cnt     <= cnt_n + (push ? 1'b1 : 1'b0);
            act     <= act_n;
            err     <= err_n;
            endp    <= endp_n;
            drop    <= drop_n;
            overrun <= ovr;
            if (push)
                mem[wr_p] <= rx_data;
        end
    end

endmodule
