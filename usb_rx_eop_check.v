//-----------------------------------------------------------------------------
// usb_rx_eop_check.v
//
// "EOP Detect + RxError Check" of the USB 2.0 PHY RX path (HS / FS / LS).
// Position:
//
//   RX front end -> NRZI Decoder -> SYNC detect -> Bit Unstuffer -> Deserializer
//                -> [THIS BLOCK] -> Elastic Buffer (CDC) -> RX output stage
//
// Packet framing.  The block turns the bit stream of usb_rx_deserializer into
// packet events and writes them into the elastic buffer:
//
//   START          on the final 1 of SYNC
//   BYTE  <data>   for every complete byte of the packet (PID first)
//   END   <err>    at the end of the packet; err = 1 marks a receive error
//
// Event word (ev_data[9:0] = {type[1:0], data[7:0]}):
//   type 01 START (data 00h), 00 BYTE (data = byte), 10 END (data[0] = error).
//
// End of packet and errors
//   HS (parameter HS = 1):
//     * EOP = bit-stuff violation (HS EOP is 01111111 before NRZI).  On the
//       violation the deserializer holds the EOP's 0 and six 1s, so a packet
//       that ended on a byte boundary has exactly 7 residual bits; any other
//       count is an error (the packet did not end on a byte boundary, or a
//       stuff error occurred inside the packet).
//     * Receiver inactive (squelch / CDR lock lost / RX disabled) before the
//       EOP: END with error.
//   FS / LS (HS = 0):
//     * EOP = SE0 bit.  The packet must end on a byte boundary (0 residual
//       bits), otherwise END with error.
//     * Bit-stuff violation: END with error at once; the rest of the packet is
//       ignored (usb_rx_sync_detect does not look for a new SYNC before the
//       SE0 of the EOP).
//     * Receiver disabled inside a packet: END with error.
//
// Elastic buffer room (buf_afull = fewer than 2 free entries, registered in the
// write domain).  A START is only written when there is room for it and its
// END; without room the whole packet is skipped (nothing is written).  A BYTE
// is only written when one entry stays free for the END; a byte that does not
// fit is dropped and the END carries the error flag.  So START / END always
// come in pairs.  Writes are at least 7 bits apart, so the one-cycle-old flag
// is safe.
//
// ovf pulses when a byte or a packet is dropped (debug / status).
//
// Clocking: one clock `clk`, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_eop_check #(
    parameter HS = 1                  // 1: HS rules, 0: FS / LS rules
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       i_en,
    input  wire       i_byte_en,
    input  wire [7:0] i_byte,
    input  wire [2:0] i_nres,
    input  wire       i_serr,
    input  wire       i_se0,
    input  wire       i_act,
    input  wire       i_sync,

    input  wire       buf_afull,

    output reg        ev_wr,
    output reg  [9:0] ev_data,
    output wire       busy,
    output reg        ovf
);

    localparam [1:0] EV_BYTE  = 2'b00;
    localparam [1:0] EV_START = 2'b01;
    localparam [1:0] EV_END   = 2'b10;

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_PKT  = 2'd1;   // packet being written
    localparam [1:0] ST_SKIP = 2'd2;   // packet skipped (no room for START)

    reg [1:0] st;
    reg       ovf_f;                   // a byte of this packet was dropped

    assign busy = (st != ST_IDLE);

    // end-of-packet condition and its error flag for the current bit
    reg end_now, end_err;
    always @* begin
        end_now = 1'b0;
        end_err = 1'b0;
        if (!i_act) begin
            end_now = 1'b1;
            end_err = 1'b1;
        end else if (HS != 0) begin
            if (i_serr) begin
                end_now = 1'b1;
                end_err = (i_nres != 3'd7);
            end
        end else begin
            if (i_se0) begin
                end_now = 1'b1;
                end_err = (i_nres != 3'd0);
            end else if (i_serr) begin
                end_now = 1'b1;
                end_err = 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= ST_IDLE;
            ovf_f   <= 1'b0;
            ev_wr   <= 1'b0;
            ev_data <= 10'd0;
            ovf     <= 1'b0;
        end else begin
            ev_wr <= 1'b0;
            ovf   <= 1'b0;
            if (i_en) begin
                case (st)
                    ST_IDLE: begin
                        if (i_sync && i_act) begin
                            if (!buf_afull) begin
                                ev_wr   <= 1'b1;
                                ev_data <= {EV_START, 8'h00};
                                ovf_f   <= 1'b0;
                                st      <= ST_PKT;
                            end else begin
                                ovf <= 1'b1;
                                st  <= ST_SKIP;
                            end
                        end
                    end

                    ST_PKT, ST_SKIP: begin
                        if (end_now) begin
                            if (st == ST_PKT) begin
                                ev_wr   <= 1'b1;
                                ev_data <= {EV_END, 7'd0, end_err | ovf_f};
                            end
                            st <= ST_IDLE;
                        end else if (i_byte_en && (st == ST_PKT)) begin
                            if (!buf_afull) begin
                                ev_wr   <= 1'b1;
                                ev_data <= {EV_BYTE, i_byte};
                            end else begin
                                ovf_f <= 1'b1;
                                ovf   <= 1'b1;
                            end
                        end
                    end

                    default: st <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
