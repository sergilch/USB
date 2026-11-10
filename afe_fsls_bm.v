//-----------------------------------------------------------------------------
// afe_fsls_bm.v - behavioural model of the FS / LS transceiver (not designed yet)
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.1 / 5.3,
// DOC/afe_interface_spec.md 3.4).  Testbench only.  Electrical convention
// (Norton *_g / *_i buses, real voltages as $realtobits): see afe_line_bm.v.
//
// Driver (fs_oe, fs_dat, fs_se0, fs_ls)
//   * Each wire is a voltage source behind R_OUT (45 Ohm: 28-44 Ohm driver
//     plus series resistor, USB 2.0).  While fs_oe = 0 the driver is off
//     (g = 0).
//   * fs_dat = 1 is J at the selected speed: FS J = DP high, LS J = DM high
//     (fs_ls = 1).  fs_se0 = 1 drives both wires low (SE0; also used as the
//     45 Ohm termination of a host during reset / chirp).
//   * Each source ramps linearly between 0 and VDD in T_FS (fs_ls = 0) or
//     T_LS (fs_ls = 1).  With 0-100 % in T_FS = 12.5 ns the 10-90 % time is
//     10 ns (USB 2.0 FS: 4-20 ns); T_LS = 187.5 ns gives 150 ns (LS: 75-300 ns).
//     The ramp is stepped in 1/25 of the ramp time.
//
// Receivers (rxdp, rxdm, rxrcv), delay T_RX
//   * rxdp / rxdm: single-ended, threshold VSE with hysteresis HYS_SE (USB 2.0:
//     low below 0.8 V, high above 2.0 V).
//   * rxrcv: differential, 1 when DP - DM > +VDI / 2, 0 when < -VDI / 2, else
//     unchanged (USB 2.0 sensitivity: 200 mV).
//   * rx_en = 0 forces rxdp = rxdm = 0 and rxrcv = 1 (isolated values of
//     DOC/afe_interface_spec.md 3.4).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_fsls_bm #(
    parameter real R_OUT  = 45.0,
    parameter real VDD    = 3.3,
    parameter real T_FS   = 12.5,     // ns, 0-100 % ramp, FS
    parameter real T_LS   = 187.5,    // ns, 0-100 % ramp, LS
    parameter real VSE    = 1.4,      // V, single-ended threshold
    parameter real HYS_SE = 0.2,      // V
    parameter real VDI    = 0.2,      // V, differential hysteresis window
    parameter real T_RX   = 2.0       // ns, receiver delay
) (
    // driver
    input  wire        fs_oe,
    input  wire        fs_dat,
    input  wire        fs_se0,
    input  wire        fs_ls,
    output reg  [63:0] dp_g, dp_i,
    output reg  [63:0] dm_g, dm_i,
    // receivers
    input  wire        rx_en,
    input  wire [63:0] dp_v,
    input  wire [63:0] dm_v,
    output reg         rxdp,
    output reg         rxdm,
    output reg         rxrcv
);
    // ---------------- driver ----------------
    real vp_src = 0.0, vm_src = 0.0;   // ramped source voltages
    real vp_tgt, vm_tgt, step;

    always @* begin
        if (fs_se0 === 1'b1) begin
            vp_tgt = 0.0; vm_tgt = 0.0;
        end else if ((fs_dat === 1'b1) ^ (fs_ls === 1'b1)) begin
            vp_tgt = VDD; vm_tgt = 0.0;          // DP high: FS J / LS K
        end else begin
            vp_tgt = 0.0; vm_tgt = VDD;          // DM high: FS K / LS J
        end
    end

    // ramp generator: steps only while a source is off target
    always begin
        step = ((fs_ls === 1'b1) ? T_LS : T_FS) / 25.0;
        if ((vp_src != vp_tgt) || (vm_src != vm_tgt)) begin
            #(step);
            vp_src = ramp(vp_src, vp_tgt, VDD / 25.0);
            vm_src = ramp(vm_src, vm_tgt, VDD / 25.0);
        end else
            @(vp_tgt or vm_tgt);
    end

    function real ramp(input real v, input real tgt, input real dv);
        begin
            if (v < tgt) ramp = (tgt - v <= dv) ? tgt : v + dv;
            else         ramp = (v - tgt <= dv) ? tgt : v - dv;
        end
    endfunction

    always @* begin
        if (fs_oe === 1'b1) begin
            dp_g = $realtobits(1.0 / R_OUT); dp_i = $realtobits(vp_src / R_OUT);
            dm_g = $realtobits(1.0 / R_OUT); dm_i = $realtobits(vm_src / R_OUT);
        end else begin
            dp_g = 64'd0; dp_i = 64'd0; dm_g = 64'd0; dm_i = 64'd0;
        end
    end

    // ---------------- receivers ----------------
    real vp, vm, vd;
    reg  sp = 1'b0, sm = 1'b0, sd = 1'b1;

    always @(dp_v or dm_v or rx_en) begin
        vp = $bitstoreal(dp_v);
        vm = $bitstoreal(dm_v);
        vd = vp - vm;
        if (vp > VSE + HYS_SE / 2.0) sp = 1'b1; else if (vp < VSE - HYS_SE / 2.0) sp = 1'b0;
        if (vm > VSE + HYS_SE / 2.0) sm = 1'b1; else if (vm < VSE - HYS_SE / 2.0) sm = 1'b0;
        if (vd > VDI / 2.0) sd = 1'b1; else if (vd < -VDI / 2.0) sd = 1'b0;
        rxdp  <= #(T_RX) (rx_en === 1'b1) ? sp : 1'b0;
        rxdm  <= #(T_RX) (rx_en === 1'b1) ? sm : 1'b0;
        rxrcv <= #(T_RX) (rx_en === 1'b1) ? sd : 1'b1;
    end
endmodule
