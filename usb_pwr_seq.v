//-----------------------------------------------------------------------------
// usb_pwr_seq.v - power-up / suspend sequencer of the PHY (digital side)
//
// WORK_PLAN 5.4 / 6.5, AFE_INTEGRATION_PLAN.md phase A7, sequence of
// DOC/afe_interface_spec.md 5.  Position:
//
//   POR_N, PWR_GOOD, PG18A (supply monitors)  --+
//   pll_lock (usb_pll_lock_det), clk_on (usb_clk_gen) --> [THIS BLOCK]
//   susp_req / clk_susp / wake (low-power control) ---+       |
//     --> bias_en, ldo_en, pll_en, iso_en                      (AFE pins)
//     --> core_rst_n_b, iso_en_b, dir_hold_b, afe_en_b, clk_en_b (clk_bit side)
//     --> state, pll_err                                       (status)
//
// Clock: ref_clk = REF_DIG, the buffered reference from the PLL block.  The
//   sequencer must run while the PLL (clk_bit) is off, so it can't use clk_bit.
//   REF_DIG lives in the VDD18A domain, which has two consequences:
//   * ldo_en (the VDD18A LDO enable) is not sequenced: it is por_n itself, on
//     as soon as the digital supply is good.  Until VDD18A is up there is no
//     ref_clk and every flop here holds its reset value (safe: isolated).
//   * VDD18A is not switched off in suspend (the sequencer would stop its own
//     clock); the PLL is only disabled (pll_en = 0).  Suspend current: Q13.
//   rst: por_n, asynchronous.  The ULPI RESETB does not reset this block.
//
// Inputs (asynchronous to ref_clk, 2-FF synchronized here):
//   pwr_good  VDD33 (analog) valid;  pg18a  VDD18A valid (PWR_GOOD of its LDO,
//             tie high for an external supply);  pll_lock (usb_pll_lock_det),
//             clk_on (usb_clk_gen);
//   susp_req  low power requested (ULPI SuspendM = 0, from the low-power
//             controller, WORK_PLAN 5.6);  clk_susp  stop CLKOUT and the PLL in
//             low power (Interface Control ClockSuspendM = 0);  wake  leave
//             low power (also when susp_req falls).
//
// Sequence (states; times in ref_clk cycles):
//   OFF     everything off: iso_en = 1, core in reset, dir_hold = 1.
//           -> BIAS when pwr_good and pg18a.
//   BIAS    bias_en = 1, wait BIAS_CYC (bandgap / bias settling, TBC Q9).
//   PLL     pll_en = 1, wait pll_lock.  No lock within LOCK_TO: pll_err = 1
//           (sticky until por_n), pll_en = 0 for OFF_CYC (RETRY), PLL again.
//   REL     lock: core reset released, iso_en = 0, CLKOUT enabled (clk_en);
//           -> RUN when clk_on (CLKOUT running).
//   RUN     afe_en = 1 (HS receiver / CDR allowed, the mode decides),
//           dir_hold = 0.
//           * susp_req: afe_en = 0;  clk_susp = 0: SUSPC (PLL and CLKOUT keep
//             running);  clk_susp = 1: clk_en = 0, dir_hold = 1, CSTOP.
//           * pll_lock lost: afe_en = 0, clk_en = 0, dir_hold = 1, CSTOP with
//             relock (the core keeps its state; the lock detector's lol flag
//             records it).
//   SUSPC   leave on wake or !susp_req: afe_en = 1, RUN.
//   CSTOP   wait clk_on = 0 (CLKOUT stopped low by usb_clk_gen, so the PLL can
//           stop without cutting a CLKOUT pulse), then pll_en = 0 for at least
//           OFF_CYC: SUSP.
//   SUSP    PLL off.  Leave when (wake or !susp_req, or a relock is pending)
//           and OFF_CYC has passed: pll_en = 1, RPLL.
//   RPLL    wait pll_lock as in PLL (timeout: pll_err, back to SUSP, retry);
//           lock: clk_en = 1, RCLK.
//   RCLK    clk_on: afe_en = 1, dir_hold = 0, RUN.
//   In all suspend / relock states iso_en stays 0 and the core stays out of
//   reset: FS/LS receivers, LineState, terminations and registers stay alive
//   (spec 5).  dir_hold covers only "no valid clock"; the low-power controller
//   ORs in its own DIR hold for low power.
//   Any state: pwr_good or pg18a low (synchronized) -> OFF at once: iso_en = 1,
//   core reset, bias_en = 0, clk_en = 0, dir_hold = 1.  pll_en follows when
//   clk_on = 0 (CLKOUT stopped low, within one CLKOUT period), or at once if
//   pg18a is low (the PLL loses its supply anyway).  BIAS starts again only
//   after pll_en is 0.
//
// clk_bit-side copies (consumers are clk_bit flops; clk_bit may be stopped):
//   core_rst_n_b  reset of the digital core: asserted asynchronously, released
//                 on the second clk_bit edge (AND it with the RESETB sync).
//   iso_en_b      asserted asynchronously (works without clk_bit, e.g. a supply
//                 loss in suspend), released on the second clk_bit edge.
//   dir_hold_b    as iso_en_b (DIR high at once, released synchronously).
//   afe_en_b      dropped asynchronously, raised on the second clk_bit edge
//                 (usb_afe_rx_if rx_en: RX_EN / CDR_EN off).
//   clk_en_b      2-FF both ways (usb_clk_gen clk_en; it samples it once per
//                 CLKOUT period).
//   The AFE pins bias_en, pll_en, iso_en come straight from ref_clk flops
//   (level shifters / isolation cells on the AFE side, spec 1); state and
//   pll_err are ref_clk-domain status (synchronized where they are read).
//
// Clocks: ref_clk (sequencer), clk_bit (output synchronizers).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_pwr_seq #(
    parameter BIAS_CYC = 240,         // 10 us at 24 MHz
    parameter LOCK_TO  = 4800,        // 200 us at 24 MHz (PLL lock budget, spec 4.3)
    parameter OFF_CYC  = 24,          // 1 us PLL off before a retry
    parameter TW       = 13           // timer width
) (
    input  wire       ref_clk,
    input  wire       clk_bit,
    input  wire       por_n,

    input  wire       pwr_good,
    input  wire       pg18a,
    input  wire       pll_lock,
    input  wire       clk_on,
    input  wire       susp_req,
    input  wire       clk_susp,
    input  wire       wake,

    // AFE pins (ref_clk flops)
    output reg        bias_en,
    output wire       ldo_en,
    output reg        pll_en,
    output reg        iso_en,

    // clk_bit side
    output wire       core_rst_n_b,
    output wire       iso_en_b,
    output wire       afe_en_b,
    output wire       dir_hold_b,
    output wire       clk_en_b,

    // status (ref_clk)
    output reg  [3:0] state,
    output reg        pll_err
);

    localparam [3:0] S_OFF   = 4'd0,
                     S_BIAS  = 4'd1,
                     S_PLL   = 4'd2,
                     S_RETRY = 4'd3,
                     S_REL   = 4'd4,
                     S_RUN   = 4'd5,
                     S_SUSPC = 4'd6,
                     S_CSTOP = 4'd7,
                     S_SUSP  = 4'd8,
                     S_RPLL  = 4'd9,
                     S_RCLK  = 4'd10;

    assign ldo_en = por_n;

    // ---------------- input synchronizers ----------------
    reg [6:0] s1, s2;
    always @(posedge ref_clk or negedge por_n) begin
        if (!por_n) begin
            s1 <= 7'd0;
            s2 <= 7'd0;
        end else begin
            s1 <= {wake, clk_susp, susp_req, clk_on, pll_lock, pg18a, pwr_good};
            s2 <= s1;
        end
    end
    wire pg_s    = s2[0] & s2[1];
    wire lock_s  = s2[2];
    wire clkon_s = s2[3];
    wire susp_s  = s2[4];
    wire csusp_s = s2[5];
    wire wake_s  = s2[6];

    // ---------------- sequencer ----------------
    reg [TW-1:0] tmr;
    reg          core_rel, afe_en, clk_en, dir_hold, relock;

    always @(posedge ref_clk or negedge por_n) begin
        if (!por_n) begin
            state     <= S_OFF;
            tmr       <= {TW{1'b0}};
            bias_en   <= 1'b0;
            pll_en    <= 1'b0;
            iso_en    <= 1'b1;
            core_rel  <= 1'b0;
            afe_en    <= 1'b0;
            clk_en    <= 1'b0;
            dir_hold  <= 1'b1;
            relock    <= 1'b0;
            pll_err   <= 1'b0;
        end else if (!pg_s) begin
            state    <= S_OFF;
            tmr      <= {TW{1'b0}};
            bias_en  <= 1'b0;
            // the PLL (VDD18A) outlives a VDD33 loss: stop CLKOUT first, so it
            // never freezes high; at once if VDD18A itself is going
            if (!clkon_s || !s2[1]) pll_en <= 1'b0;
            iso_en   <= 1'b1;
            core_rel <= 1'b0;
            afe_en   <= 1'b0;
            clk_en   <= 1'b0;
            dir_hold <= 1'b1;
            relock   <= 1'b0;
        end else begin
            if (tmr != {TW{1'b0}}) tmr <= tmr - 1'b1;
            case (state)
                S_OFF:
                    if (!pll_en) begin
                        bias_en <= 1'b1;
                        tmr     <= BIAS_CYC;
                        state   <= S_BIAS;
                    end else if (!clkon_s)
                        pll_en  <= 1'b0;
                S_BIAS:
                    if (tmr == {TW{1'b0}}) begin
                        pll_en <= 1'b1;
                        tmr    <= LOCK_TO;
                        state  <= S_PLL;
                    end
                S_PLL, S_RPLL:
                    if (lock_s) begin
                        clk_en <= 1'b1;
                        relock <= 1'b0;
                        if (state == S_PLL) begin
                            core_rel <= 1'b1;
                            iso_en   <= 1'b0;
                            state    <= S_REL;
                        end else
                            state    <= S_RCLK;
                    end else if (tmr == {TW{1'b0}}) begin
                        pll_err <= 1'b1;
                        pll_en  <= 1'b0;
                        tmr     <= OFF_CYC;
                        state   <= (state == S_PLL) ? S_RETRY : S_SUSP;
                    end
                S_RETRY:
                    if (tmr == {TW{1'b0}}) begin
                        pll_en <= 1'b1;
                        tmr    <= LOCK_TO;
                        state  <= S_PLL;
                    end
                S_REL, S_RCLK:
                    if (clkon_s) begin
                        afe_en   <= 1'b1;
                        dir_hold <= 1'b0;
                        state    <= S_RUN;
                    end
                S_RUN:
                    if (!lock_s) begin
                        afe_en   <= 1'b0;
                        clk_en   <= 1'b0;
                        dir_hold <= 1'b1;
                        relock   <= 1'b1;
                        state    <= S_CSTOP;
                    end else if (susp_s) begin
                        afe_en <= 1'b0;
                        if (csusp_s) begin
                            clk_en   <= 1'b0;
                            dir_hold <= 1'b1;
                            state    <= S_CSTOP;
                        end else
                            state    <= S_SUSPC;
                    end
                S_SUSPC:
                    if (!lock_s) begin
                        clk_en   <= 1'b0;
                        dir_hold <= 1'b1;
                        relock   <= 1'b1;
                        state    <= S_CSTOP;
                    end else if (!susp_s || wake_s) begin
                        afe_en <= 1'b1;
                        state  <= S_RUN;
                    end
                S_CSTOP:
                    if (!clkon_s) begin
                        pll_en <= 1'b0;
                        tmr    <= OFF_CYC;            // minimum off time
                        state  <= S_SUSP;
                    end
                S_SUSP:
                    if ((relock || !susp_s || wake_s) && (tmr == {TW{1'b0}})) begin
                        pll_en <= 1'b1;
                        tmr    <= LOCK_TO;
                        state  <= S_RPLL;
                    end
                default: state <= S_OFF;
            endcase
        end
    end

    // ---------------- clk_bit-side copies ----------------
    // core reset: async assert, sync release
    reg [1:0] rs;
    always @(posedge clk_bit or negedge core_rel) begin
        if (!core_rel) rs <= 2'b00;
        else           rs <= {rs[0], 1'b1};
    end
    assign core_rst_n_b = rs[1];

    // isolation and DIR hold: async assert, sync release
    reg [1:0] iso_s, dh_s;
    always @(posedge clk_bit or posedge iso_en) begin
        if (iso_en) iso_s <= 2'b11;
        else        iso_s <= {iso_s[0], 1'b0};
    end
    assign iso_en_b = iso_s[1];
    always @(posedge clk_bit or posedge dir_hold) begin
        if (dir_hold) dh_s <= 2'b11;
        else          dh_s <= {dh_s[0], 1'b0};
    end
    assign dir_hold_b = dh_s[1];

    // HS AFE enable: async drop, sync rise
    reg [1:0] ae;
    always @(posedge clk_bit or negedge afe_en) begin
        if (!afe_en) ae <= 2'b00;
        else         ae <= {ae[0], 1'b1};
    end
    assign afe_en_b = ae[1];

    // CLKOUT enable: plain 2-FF
    reg [1:0] cen_s;
    always @(posedge clk_bit or negedge por_n) begin
        if (!por_n) cen_s <= 2'b00;
        else        cen_s <= {cen_s[0], clk_en};
    end
    assign clk_en_b = cen_s[1];

endmodule
