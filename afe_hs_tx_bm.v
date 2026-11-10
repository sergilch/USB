//-----------------------------------------------------------------------------
// afe_hs_tx_bm.v - behavioural model of the HS transmitter (analog TX block)
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.3).  Testbench
// only.  Pin names follow the analog block (TX_IN_P / TX_IN_N / TX_EN);
// electrical convention (Norton *_g / *_i buses): see afe_line_bm.v.
//
// Behaviour
//   * Current-mode driver: I_HS (17.78 mA) is steered into DP when TX_IN_P = 1,
//     TX_IN_N = 0 (J, polarity as proposed in DOC/afe_interface_spec.md 3.1,
//     still TBC) and into DM for TX_IN_P = 0, TX_IN_N = 1.  Ideal current
//     source (g = 0): into the two 45 Ohm terminations of an HS link that
//     gives 17.78 mA * 22.5 Ohm = 400 mV; into one 45 Ohm (chirp, far end
//     driving SE0) about 800 mV.
//   * TX_EN: the current reaches the line only T_EN after TX_EN rises
//     (settling of the current source, I4 / Q4); before that, and while
//     TX_EN = 0, no current flows into the line.  `settled` shows the state.
//   * T_DLY: transport delay TX_IN -> line.
//   * TX_IN_P = TX_IN_N while settled: the current splits half / half (no
//     differential signal).  If that lasts longer than T_SKEW_MAX, it is a
//     P/N skew or a glitch at the boundary: `skew_err` counts the events.
//   * I_SCALE models the amplitude trim (1.0 = nominal).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_hs_tx_bm #(
    parameter real I_HS       = 17.78e-3,   // A
    parameter real T_EN       = 20.0,       // ns, TX_EN -> current settled
    parameter real T_DLY      = 0.5,        // ns, TX_IN -> line
    parameter real T_SKEW_MAX = 0.1         // ns, longest tolerated P = N
) (
    input  wire        TX_IN_P,
    input  wire        TX_IN_N,
    input  wire        TX_EN,
    output reg  [63:0] dp_g, dp_i,
    output reg  [63:0] dm_g, dm_i,
    output reg         settled,
    output integer     skew_err
);
    real i_scale = 1.0;                     // set hierarchically for trim tests

    reg p_d = 1'b0, n_d = 1'b0;
    always @(TX_IN_P) p_d <= #(T_DLY) TX_IN_P;
    always @(TX_IN_N) n_d <= #(T_DLY) TX_IN_N;

    // settling: `settled` rises T_EN after TX_EN rose, if TX_EN did not fall
    // in between (transport-delayed copy + time of the last fall, race-free)
    real t_fall = -1.0e9;
    reg  en_d   = 1'b0;
    initial begin settled = 1'b0; skew_err = 0; end
    always @(TX_EN) begin
        if (TX_EN !== 1'b1) begin settled = 1'b0; t_fall = $realtime; end
        en_d <= #(T_EN) TX_EN;
    end
    always @(posedge en_d)
        if ((TX_EN === 1'b1) && ($realtime - t_fall >= T_EN - 1.0e-6)) settled = 1'b1;

    // P = N longer than T_SKEW_MAX while settled
    wire eq = settled && (p_d === n_d);
    real t_eq_fall = -1.0e9;
    reg  eq_d      = 1'b0;
    always @(eq) begin
        if (!eq) t_eq_fall = $realtime;
        eq_d <= #(T_SKEW_MAX) eq;
    end
    always @(posedge eq_d)
        if (eq && ($realtime - t_eq_fall >= T_SKEW_MAX - 1.0e-6)) skew_err = skew_err + 1;

    real ip, im;
    always @* begin
        ip = 0.0; im = 0.0;
        if (settled) begin
            if      (p_d === 1'b1 && n_d === 1'b0) ip = I_HS * i_scale;
            else if (p_d === 1'b0 && n_d === 1'b1) im = I_HS * i_scale;
            else begin ip = 0.5 * I_HS * i_scale; im = 0.5 * I_HS * i_scale; end
        end
        dp_g = 64'd0; dm_g = 64'd0;
        dp_i = $realtobits(ip);
        dm_i = $realtobits(im);
    end
endmodule
