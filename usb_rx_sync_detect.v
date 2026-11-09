//-----------------------------------------------------------------------------
// usb_rx_sync_detect.v
//
// "SYNC Detect" of the USB 2.0 PHY RX path (HS / FS / LS).  Position:
//
//   RX front end -> NRZI Decoder -> [THIS BLOCK] -> Bit Unstuffer -> Deserializer
//                                                               -> EOP / RxError check
//
// In the block diagram SYNC detection is drawn together with the deserializer.
// It is a separate stage here, in front of the unstuffer, because the trailing
// 1 of SYNC already counts as the first one of a stuffing run: the unstuffer
// must know where SYNC ends before it sees the first PID bit.
//
// SYNC pattern (decoded bits): a run of 0s (KJKJ... on the line) ended by a 1
//   (the final KK).  HS SYNC is 32 bits, FS / LS SYNC 8 bits.  Leading bits may
//   be lost (HS: squelch / CDR acquisition, up to 4 bits per hub; the shortest
//   HS SYNC a receiver may see is 12 bits), so the detector only needs ZMIN
//   zeros before the 1.  Defaults: HS ZMIN = 6, FS / LS ZMIN = 4 (set per
//   instance).
//
// States
//   hunting : looking for SYNC.  A 1 after >= ZMIN consecutive 0s is the end of
//             SYNC: o_sync = 1 on that bit, the detector leaves the hunting state.
//   packet  : no further SYNC search until the packet is over, so data that
//             looks like SYNC is never taken for a new packet.  Hunting starts
//             again (rearm) on an SE0 bit (FS / LS EOP or reset) or when the
//             receiver becomes inactive (HS squelch).
//
// Interface: the bit-serial stream of usb_rx_nrzi_decoder (i_en, i_bit, i_se0,
//   i_act), registered and passed on with two sideband bits:
//     o_sync : this bit is the final 1 of SYNC (it is not a data bit);
//     o_pkt  : a packet was in progress before this bit (data bits, and the
//              EOP / line-drop bit that ends the packet).
//
// Clocking: one clock `clk`, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_sync_detect #(
    parameter ZMIN = 6                // zeros needed in front of the final 1 (1..15)
) (
    input  wire clk,
    input  wire rst_n,

    input  wire i_en,
    input  wire i_bit,
    input  wire i_se0,
    input  wire i_act,

    output reg  o_en,
    output reg  o_bit,
    output reg  o_se0,
    output reg  o_act,
    output reg  o_sync,
    output reg  o_pkt
);

    reg       hunt;
    reg [3:0] zc;                     // consecutive zeros, saturating

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hunt   <= 1'b1;
            zc     <= 4'd0;
            o_en   <= 1'b0;
            o_bit  <= 1'b1;
            o_se0  <= 1'b0;
            o_act  <= 1'b0;
            o_sync <= 1'b0;
            o_pkt  <= 1'b0;
        end else begin
            o_en   <= i_en;
            o_sync <= 1'b0;
            if (i_en) begin
                o_bit <= i_bit;
                o_se0 <= i_se0;
                o_act <= i_act;
                o_pkt <= !hunt;
                if (!i_act || i_se0) begin
                    hunt <= 1'b1;                       // rearm
                    zc   <= 4'd0;
                end else if (hunt) begin
                    if (!i_bit) begin
                        if (zc != 4'd15) zc <= zc + 4'd1;
                    end else begin
                        if (zc >= ZMIN) begin
                            o_sync <= 1'b1;
                            hunt   <= 1'b0;
                        end
                        zc <= 4'd0;
                    end
                end
            end
        end
    end

endmodule
