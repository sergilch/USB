//-----------------------------------------------------------------------------
// usb_rx_deserializer.v
//
// "Deserializer 1:8" of the USB 2.0 PHY RX path (HS / FS / LS).  Position:
//
//   RX front end -> NRZI Decoder -> SYNC detect -> Bit Unstuffer -> [THIS BLOCK]
//                                                               -> EOP / RxError check
//
// Collects the data bits of a packet (i_dat from usb_rx_bit_unstuffer) into
// bytes, LSB first.  Byte alignment comes from SYNC: the bit counter is cleared
// on the final 1 of SYNC (i_sync), so the first byte is the PID.
//
// Interface: the stream of usb_rx_bit_unstuffer, registered, with
//   o_byte_en / o_byte : a byte is complete with this bit;
//   o_nres             : data bits held after this bit (0..7) - the EOP check
//                        uses it on the EOP bit to see whether the packet ended
//                        on a byte boundary;
//   o_en, o_serr, o_se0, o_act, o_sync passed through.
//
// Clocking: one clock `clk`, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_deserializer (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       i_en,
    input  wire       i_dat,
    input  wire       i_bit,
    input  wire       i_serr,
    input  wire       i_se0,
    input  wire       i_act,
    input  wire       i_sync,

    output reg        o_en,
    output reg        o_byte_en,
    output reg  [7:0] o_byte,
    output reg  [2:0] o_nres,
    output reg        o_serr,
    output reg        o_se0,
    output reg        o_act,
    output reg        o_sync
);

    reg [7:0] sh;                     // bit 0 = first received bit of the byte
    reg [2:0] n;                      // data bits held (0..7)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh        <= 8'd0;
            n         <= 3'd0;
            o_en      <= 1'b0;
            o_byte_en <= 1'b0;
            o_byte    <= 8'd0;
            o_nres    <= 3'd0;
            o_serr    <= 1'b0;
            o_se0     <= 1'b0;
            o_act     <= 1'b0;
            o_sync    <= 1'b0;
        end else begin
            o_en      <= i_en;
            o_byte_en <= 1'b0;
            o_serr    <= 1'b0;
            o_sync    <= 1'b0;
            if (i_en) begin
                o_serr <= i_serr;
                o_se0  <= i_se0;
                o_act  <= i_act;
                o_sync <= i_sync;
                if (i_sync) begin
                    n      <= 3'd0;
                    o_nres <= 3'd0;
                end else if (i_dat) begin
                    sh <= {i_bit, sh[7:1]};
                    if (n == 3'd7) begin
                        o_byte_en <= 1'b1;
                        o_byte    <= {i_bit, sh[7:1]};
                    end
                    n      <= n + 3'd1;                 // wraps 7 -> 0
                    o_nres <= n + 3'd1;
                end else begin
                    o_nres <= n;
                end
            end
        end
    end

endmodule
