//-----------------------------------------------------------------------------
// afe_line_bm.v - behavioural model of the USB DP / DM wires (testbench only)
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md, phase A1).
// Not synthesizable; never read by run_synth.sh (only usb_*.v are).
//
// Electrical convention shared by all afe_*_bm models
//   Every block that loads or drives a wire exports, per wire, its Norton
//   equivalent as two 64-bit buses holding a Verilog real ($realtobits):
//     *_g : conductance to the wire, in siemens (0 for an ideal current source)
//     *_i : Norton current into the wire, in amperes (G * Vsource + Isource)
//   An unused contributor is tied to 64'd0, which is the bit pattern of 0.0.
//   This model sums up to six contributors per wire and solves the node:
//       V = sum(i) / (sum(g) + G_LEAK)
//   and exports the wire voltages (volts) the same way: dp_v / dm_v.
//
// Limits (on purpose): one lumped DC node per wire, no cable transmission line,
//   no reflections, no capacitance.  Edges are as fast as the drivers make them
//   (HS: instantaneous current steering, FS / LS: ramped source in
//   afe_fsls_bm).  T_LINE delays the voltages seen by all receivers alike.
//   That is enough to check levels (HS 400 mV, chirp 800 mV, FS / LS idle,
//   SE0), squelch / disconnect thresholds and the digital timing around the
//   AFE; eye diagrams and signal integrity belong to the analog simulation
//   (phase A8).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_line_bm #(
    parameter real G_LEAK = 1.0e-9,     // S, keeps an undriven wire at 0 V
    parameter real T_LINE = 0.0         // ns, transport delay to the receivers
) (
    input  wire [63:0] dp_g0, dp_i0, dp_g1, dp_i1, dp_g2, dp_i2,
    input  wire [63:0] dp_g3, dp_i3, dp_g4, dp_i4, dp_g5, dp_i5,
    input  wire [63:0] dm_g0, dm_i0, dm_g1, dm_i1, dm_g2, dm_i2,
    input  wire [63:0] dm_g3, dm_i3, dm_g4, dm_i4, dm_g5, dm_i5,
    output reg  [63:0] dp_v,
    output reg  [63:0] dm_v
);
    real gp, ip, gm, im, vp, vm;

    initial begin
        dp_v = $realtobits(0.0);
        dm_v = $realtobits(0.0);
    end

    always @* begin
        gp = G_LEAK + $bitstoreal(dp_g0) + $bitstoreal(dp_g1) + $bitstoreal(dp_g2)
                    + $bitstoreal(dp_g3) + $bitstoreal(dp_g4) + $bitstoreal(dp_g5);
        ip = $bitstoreal(dp_i0) + $bitstoreal(dp_i1) + $bitstoreal(dp_i2)
           + $bitstoreal(dp_i3) + $bitstoreal(dp_i4) + $bitstoreal(dp_i5);
        gm = G_LEAK + $bitstoreal(dm_g0) + $bitstoreal(dm_g1) + $bitstoreal(dm_g2)
                    + $bitstoreal(dm_g3) + $bitstoreal(dm_g4) + $bitstoreal(dm_g5);
        im = $bitstoreal(dm_i0) + $bitstoreal(dm_i1) + $bitstoreal(dm_i2)
           + $bitstoreal(dm_i3) + $bitstoreal(dm_i4) + $bitstoreal(dm_i5);
        vp = ip / gp;
        vm = im / gm;
        dp_v <= #(T_LINE) $realtobits(vp);
        dm_v <= #(T_LINE) $realtobits(vm);
    end
endmodule
