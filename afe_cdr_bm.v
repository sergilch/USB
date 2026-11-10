//-----------------------------------------------------------------------------
// afe_cdr_bm.v - behavioural model of the PLL-assisted bang-bang CDR (upper loop)
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.3).  Testbench
// only.  Pin names follow the analog block (CDR_DATA in); the outputs are the
// digital-side names of DOC/afe_interface_spec.md 3.2 (clk_rx, hs_rxd).  The
// retimed data output does not exist in the analog design yet (Q1); the model
// assumes it as proposed.
//
// Behaviour
//   * VCO: free-runs at T_BIT * (1 + PPM * 1e-6) (the coarse loop from the
//     PLL holds it near 480 MHz; PPM models the remaining mismatch, R3), plus
//     a uniform random period jitter of +-JIT.
//   * Alexander phase detector: CDR_DATA is sampled on the rising clk_rx edge
//     (data, d) and on the falling edge (edge, e).  For a data transition
//     between two rising edges (d_prev != d):
//       e == d_prev : the transition came after the falling edge, the clock is
//                     early -> the next rising edge moves later by STEP;
//       e == d      : the transition came before it, the clock is late ->
//                     the next rising edge moves earlier by STEP.
//     No transition: no correction.  KI adds an integral (frequency) path:
//     the VCO period changes by +-KI per decision.  STEP / KI are module
//     variables (start values from the parameters), so testbenches can sweep
//     them hierarchically.
//   * Sampling ambiguity: a sample taken less than T_AMB after a CDR_DATA
//     change is random (metastable / unresolved sample).
//   * Retimed data: hs_rxd = the rising-edge sample, T_CQ after that edge.  A
//     digital flop on the next rising clk_rx edge captures it with setup
//     T_BIT - T_CQ and hold T_CQ.
//   * CDR_EN = 0: clk_rx stops low, hs_rxd = 1 (isolated value).  On enable
//     the VCO starts at a random phase.
//   * n_up / n_dn count the phase decisions (later / earlier), n_bits the
//     rising edges, for the testbenches.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_cdr_bm #(
    parameter real    T_BIT  = 2.0833333,  // ns
    parameter real    PPM    = 0.0,
    parameter real    P_STEP = 0.13,       // ns per decision (about T_BIT / 16)
    parameter real    P_KI   = 0.0,        // ns per decision
    parameter real    JIT    = 0.0,        // ns, peak period jitter
    parameter real    T_AMB  = 0.03,       // ns
    parameter real    T_CQ   = 0.3,        // ns
    parameter integer SEED   = 5
) (
    input  wire    CDR_DATA,
    input  wire    CDR_EN,
    output reg     clk_rx,
    output reg     hs_rxd,
    output integer n_up,
    output integer n_dn,
    output integer n_bits
);
    real STEP = P_STEP;
    real KI   = P_KI;

    integer seed = SEED;
    real    t_dchg = -1.0e9;
    real    per, f_int, adj, half;
    reg     d, d_prev, e;

    always @(CDR_DATA) t_dchg = $realtime;

    function smp(input dummy);
        begin
            if (($realtime - t_dchg) < T_AMB) smp = $random(seed);
            else                              smp = (CDR_DATA === 1'b1);
        end
    endfunction

    function real jit(input dummy);
        begin
            jit = (JIT > 0.0) ? JIT * (($random(seed) % 10000) / 10000.0) : 0.0;
        end
    endfunction

    initial begin
        clk_rx = 1'b0; hs_rxd = 1'b1;
        n_up = 0; n_dn = 0; n_bits = 0;
        f_int = 0.0; d_prev = 1'b0; e = 1'b0;
    end

    always begin
        if (CDR_EN !== 1'b1) begin
            clk_rx = 1'b0;
            hs_rxd <= #(T_CQ) 1'b1;
            wait (CDR_EN === 1'b1);
            #(T_BIT * ({$random(seed)} % 1000) / 1000.0);     // random start phase
        end
        // rising edge: data sample + phase decision
        clk_rx = 1'b1;
        n_bits = n_bits + 1;
        d = smp(1'b0);
        adj = 0.0;
        if (d != d_prev) begin
            if (e == d_prev) begin adj =  STEP; n_up = n_up + 1; f_int = f_int + KI; end
            else             begin adj = -STEP; n_dn = n_dn + 1; f_int = f_int - KI; end
        end
        d_prev = d;
        hs_rxd <= #(T_CQ) d;
        per  = T_BIT * (1.0 + PPM * 1.0e-6) + f_int;
        half = per / 2.0 + jit(1'b0);
        #(half);
        // falling edge: edge sample
        clk_rx = 1'b0;
        e = smp(1'b0);
        half = per / 2.0 + adj + jit(1'b0);
        if (half < 0.1) half = 0.1;
        #(half);
    end
endmodule
