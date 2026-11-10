//-----------------------------------------------------------------------------
// afe_squelch_bm.v - behavioural model of the HS squelch and disconnect detectors
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.1 / 5.3,
// DOC/afe_interface_spec.md 3.2 / 3.5).  Testbench only.  These analog blocks
// are not designed yet; the model gives the digital side their behaviour.
//
//   squelch: 1 = no HS signal.  The line counts as active while
//            |DP - DM| > V_SQ (USB 2.0: squelch below 100 mV, active above
//            150 mV, default 125 mV).  squelch falls once the line has been
//            active for T_SQ_ON (response time, Q2) and rises once it has been
//            inactive for T_SQ_OFF (envelope hold: the differential voltage
//            passes zero at every HS transition, so short gaps must not count).
//            Both are inertial filters: shorter activity / gaps are ignored.
//   disc   : 1 = disconnect envelope.  |DP - DM| > V_DISC (USB 2.0: 525-625 mV,
//            default 575 mV) for T_DISC.  The host samples it during the HS EOP.
//   en = 0 : squelch = 1, disc = 0 (isolated values).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_squelch_bm #(
    parameter real V_SQ     = 0.125,
    parameter real T_SQ_ON  = 4.0,    // ns, active -> squelch falls
    parameter real T_SQ_OFF = 12.0,   // ns, idle -> squelch rises
    parameter real V_DISC   = 0.575,
    parameter real T_DISC   = 4.0     // ns
) (
    input  wire [63:0] dp_v,
    input  wire [63:0] dm_v,
    input  wire        en,
    output wire        squelch,
    output wire        disc
);
    real vd;
    reg  act_raw  = 1'b0;
    reg  disc_raw = 1'b0;

    always @(dp_v or dm_v) begin
        vd = $bitstoreal(dp_v) - $bitstoreal(dm_v);
        if (vd < 0.0) vd = -vd;
        act_raw  = (vd > V_SQ);
        disc_raw = (vd > V_DISC);
    end

    // inertial filters: rise delay, fall delay
    wire act_f, disc_f;
    assign #(T_SQ_ON, T_SQ_OFF) act_f  = act_raw;
    assign #(T_DISC, 0.0)       disc_f = disc_raw;

    assign squelch = (en === 1'b1) ? !(act_f === 1'b1) : 1'b1;
    assign disc    = (en === 1'b1) ?  (disc_f === 1'b1) : 1'b0;
endmodule
