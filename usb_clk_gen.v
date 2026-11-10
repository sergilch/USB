//-----------------------------------------------------------------------------
// usb_clk_gen.v - ce60 and the ULPI CLKOUT (60 MHz) from the 480 MHz PLL clock
//
// WORK_PLAN 5.2, AFE_INTEGRATION_PLAN.md 3.4 / phase A4, DOC/afe_interface_spec.md 2.
//
//   PLL clk_bit (480 MHz) -> [THIS BLOCK] -> ce60  (clock enable of the ULPI domain)
//                                         -> clk60 (CLKOUT, to the CLK pad)
//
// Timing (as assumed by usb_ulpi_phy_pads and its testbench)
//   * A free-running 3-bit counter on clk_bit.  ce60 is high in one cycle of
//     eight (registered, cnt = 7).
//   * clk60 is a flop on the falling clk_bit edge: it rises in the middle of
//     the ce60 cycle, half a clk_bit period before the edge on which the core
//     samples and launches (ce60 = 1), and falls 4 clk_bit cycles later.  So
//     high and low are 4 clk_bit cycles each (50 % duty), and the core's ULPI
//     outputs change about 1 ns after the CLKOUT edge (clock-to-out / hold for
//     the Link).
//   * The half-cycle paths into the falling-edge flop come from flops (rise /
//     fall flags), one mux deep.
//
// Glitch-free start / stop
//   clk_en (pll_lock & ~clock suspend, clk_bit domain) is sampled once per
//   period, in the cycle before clk60 would rise.  If it is 0, that rising edge
//   and the whole period are skipped; a pulse that has started always runs to
//   its end.  So clk60 only ever shows complete 4 + 4 periods, and stops low.
//   clk_on = 1 while clk60 is running (updated at the same decision point), so
//   a power sequencer can wait for clk_on = 0 before it stops the PLL: clk_bit
//   must not stop while clk60 is high (the stop itself would cut the pulse).
//   ce60 keeps running whenever clk_bit runs.
//
// Reset: rst_n is the clock domain's reset (power-on), not the ULPI RESETB:
//   CLKOUT must keep running while the Link holds RESETB low.  Asynchronous
//   assert; clk60 = 0, ce60 = 0, clk_on = 0 during reset.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_clk_gen (
    input  wire clk_bit,
    input  wire rst_n,
    input  wire clk_en,         // CLKOUT allowed
    output reg  ce60,
    output reg  clk60,          // CLKOUT
    output reg  clk_on          // CLKOUT is running
);

    reg [2:0] cnt;
    reg       rise, fall;       // clk60 edge requests for the falling-edge flop

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            cnt    <= 3'd0;
            ce60   <= 1'b0;
            rise   <= 1'b0;
            fall   <= 1'b0;
            clk_on <= 1'b0;
        end else begin
            cnt  <= cnt + 3'd1;
            ce60 <= (cnt == 3'd6);
            rise <= (cnt == 3'd6) & clk_en;      // high in the ce60 cycle
            fall <= (cnt == 3'd2);               // high in the cycle cnt = 3
            if (cnt == 3'd6) clk_on <= clk_en;
        end
    end

    always @(negedge clk_bit or negedge rst_n) begin
        if (!rst_n)    clk60 <= 1'b0;
        else if (rise) clk60 <= 1'b1;
        else if (fall) clk60 <= 1'b0;
    end

endmodule
