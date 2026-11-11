//-----------------------------------------------------------------------------
// usb_rx_status_flt.v
//
// Inertial filter for one synchronized status bit (used by
// usb_rx_status_sync for squelch, disconnect and the VBUS / ID comparators).
//   On every enabled cycle: if din equals dout, the counter clears; otherwise
//   it counts, and when it has reached len, dout takes din (so din must differ
//   from dout on len + 1 consecutive enabled cycles).  len = 0: dout follows din
//   with one enabled cycle of delay.
//
// Clocking: clk with enable en; active-low asynchronous reset to RST_V.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_status_flt #(
    parameter       W     = 4,
    parameter [0:0] RST_V = 1'b0
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire         din,
    input  wire [W-1:0] len,
    output reg          dout
);
    reg [W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= RST_V;
            cnt  <= {W{1'b0}};
        end else if (en) begin
            if (din == dout)
                cnt <= {W{1'b0}};
            else if (cnt >= len) begin
                dout <= din;
                cnt  <= {W{1'b0}};
            end else
                cnt <= cnt + 1'b1;
        end
    end
endmodule
