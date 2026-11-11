//-----------------------------------------------------------------------------
// afe_squelch_bm.v - behavioural model of the HS squelch and disconnect detectors
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.1 / 5.3,
// DOC/afe_interface_spec.md 3.2 / 3.5).  Testbench only.  These analog blocks
// are not designed yet; the model gives the digital side their behaviour.
//
//   squelch: 1 = no HS signal.  The line counts as active while
//            |DP - DM| > V_SQ (USB 2.0: squelch below 100 mV, active above
//            150 mV, default 125 mV).  The differential voltage passes zero at
//            every HS transition; with finite edges (625 ps) it stays below
//            125 mV for about 0.2 ns per bit.  So the comparator feeds an
//            envelope that bridges dips shorter than T_BRIDGE (1 ns, less than
//            a bit time).  squelch falls once the envelope has been active for
//            T_SQ_ON (response time, Q2) and rises once the line has been
//            inactive for T_SQ_OFF in total (T_BRIDGE + the rest).  Both are
//            inertial: activity shorter than T_SQ_ON - T_BRIDGE and gaps
//            shorter than T_SQ_OFF are ignored.  Without the bridge every zero
//            crossing restarted the T_SQ_ON filter, so the squelch never
//            released on alternating data with sloped edges (the line model
//            afe_line_bm has instantaneous edges, which hid this).  Same
//            behaviour as afe_squelch in AFE/veriloga/afe_receiver.va.
//            T_ON / T_OFF / T_BRIDGE are module variables (start values
//            T_SQ_ON / T_SQ_OFF / T_SQ_BRIDGE), so testbenches can sweep them
//            hierarchically.
//   disc   : 1 = disconnect envelope.  |DP - DM| > V_DISC (USB 2.0: 525-625 mV,
//            default 575 mV) for T_DISC.  The host samples it during the HS EOP.
//   en = 0 : squelch = 1, disc = 0 (isolated values).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_squelch_bm #(
    parameter real V_SQ     = 0.125,
    parameter real T_SQ_ON  = 4.0,    // ns, active -> squelch falls
    parameter real T_SQ_OFF = 12.0,   // ns, idle -> squelch rises
    parameter real T_SQ_BRIDGE = 1.0, // ns, shorter dips below V_SQ are ignored
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

    // envelope: follows act_raw up at once; falls only after act_raw has been
    // low for T_BRIDGE.  Every fall of act_raw schedules a check; it applies
    // only if act_raw has not changed since (n_raw unchanged).
    real    T_BRIDGE = T_SQ_BRIDGE;
    integer n_raw = 0, br_chk = 0;
    reg     env   = 1'b0;
    always @(act_raw) begin
        n_raw = n_raw + 1;
        if (act_raw) env = 1'b1;
        else         br_chk <= #(T_BRIDGE) n_raw;
    end
    always @(br_chk)
        if ((br_chk == n_raw) && !act_raw) env = 1'b0;

    // squelch: inertial filter on the envelope with run-time delays T_ON and
    // T_OFF - T_BRIDGE (module variables, so testbenches can sweep them).
    // Every change of env schedules a check after the delay that applies to
    // the new value; the output follows only if env has not changed in between.
    real    T_ON  = T_SQ_ON;
    real    T_OFF = T_SQ_OFF;
    real    t_chg = 0.0, t_need = 0.0;
    integer n_chg = 0, chk = 0;
    reg     act_f = 1'b0;
    always @(env) begin
        t_chg  = $realtime;
        t_need = env ? T_ON : ((T_OFF > T_BRIDGE) ? T_OFF - T_BRIDGE : 0.0);
        n_chg  = n_chg + 1;
        chk   <= #(t_need) n_chg;
    end
    always @(chk)
        if ((chk == n_chg) && ($realtime - t_chg >= t_need - 1.0e-6)) act_f = env;

    // disconnect: fixed inertial rise delay
    wire disc_f;
    assign #(T_DISC, 0.0) disc_f = disc_raw;

    assign squelch = (en === 1'b1) ? !(act_f === 1'b1) : 1'b1;
    assign disc    = (en === 1'b1) ?  (disc_f === 1'b1) : 1'b0;
endmodule
