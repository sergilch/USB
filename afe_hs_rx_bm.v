//-----------------------------------------------------------------------------
// afe_hs_rx_bm.v - behavioural model of the HS receiver (analog RX block)
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.3).  Testbench
// only.  Pin names follow the analog block (RX_OUT_P / RX_OUT_N); the inputs
// are the wire voltages of afe_line_bm (real, $realtobits).
//
// Behaviour: differential Schmitt trigger, as described by the analog team.
//   * RX_OUT_P = 1 when DP - DM - V_OFF > +V_HYS / 2, 0 when < -V_HYS / 2,
//     otherwise unchanged (polarity as proposed, Q3).  RX_OUT_N = !RX_OUT_P.
//   * Noise: every T_NOISE the input is re-evaluated with a uniform random
//     offset of +-V_NOISE.  On an idle line (SE0, 0 V differential) this makes
//     the output toggle at random, as a real receiver with hysteresis below
//     the noise does; the CDR and SYNC detection must cope with that before
//     squelch / lock.  V_NOISE = 0 switches it off.
//   * T_DLY: delay input -> output.  RX_EN = 0 (proposed pin, spec 3.2):
//     RX_OUT_P = 0, RX_OUT_N = 1.
//   * V_HYS, V_OFF, V_NOISE are module variables, so testbenches can sweep
//     them hierarchically; the parameters set the start values.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_hs_rx_bm #(
    parameter real P_HYS   = 0.020,   // V, total hysteresis
    parameter real P_OFF   = 0.0,     // V, input offset
    parameter real P_NOISE = 0.015,   // V, peak uniform noise
    parameter real T_NOISE = 1.0,     // ns
    parameter real T_DLY   = 0.3,     // ns
    parameter integer SEED = 11
) (
    input  wire [63:0] dp_v,
    input  wire [63:0] dm_v,
    input  wire        RX_EN,
    output reg         RX_OUT_P,
    output reg         RX_OUT_N
);
    real V_HYS   = P_HYS;
    real V_OFF   = P_OFF;
    real V_NOISE = P_NOISE;

    integer seed = SEED;
    reg     st = 1'b0;
    real    vd, n;

    initial begin RX_OUT_P = 1'b0; RX_OUT_N = 1'b1; end

    task eval;
        begin
            n  = (V_NOISE > 0.0) ? V_NOISE * (($random(seed) % 10000) / 10000.0) : 0.0;
            vd = $bitstoreal(dp_v) - $bitstoreal(dm_v) - V_OFF + n;
            if (vd > V_HYS / 2.0) st = 1'b1; else if (vd < -V_HYS / 2.0) st = 1'b0;
            RX_OUT_P <= #(T_DLY) (RX_EN === 1'b1) ?  st : 1'b0;
            RX_OUT_N <= #(T_DLY) (RX_EN === 1'b1) ? !st : 1'b1;
        end
    endtask

    always @(dp_v or dm_v or RX_EN) eval;
    always #(T_NOISE) if (V_NOISE > 0.0) eval;
endmodule
