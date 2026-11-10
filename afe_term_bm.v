//-----------------------------------------------------------------------------
// afe_term_bm.v - behavioural model of the switchable USB terminations / pulls
//
// Part of the AFE behavioural models (AFE_INTEGRATION_PLAN.md 5.1 / 5.3,
// DOC/afe_interface_spec.md 3.5).  Testbench only.  Electrical convention
// (Norton *_g / *_i buses, $realtobits): see afe_line_bm.v.
//
//   dp_pullup_en   : R_PU (1.5 kOhm) from DP to VDD   (FS device attach)
//   dm_pullup_en   : R_PU from DM to VDD               (LS device attach)
//   hs_term_en     : R_HS (45 Ohm) from DP and DM to ground (HS termination)
//   dp_pulldown_en : R_PD (15 kOhm) from DP to ground  (host / OTG)
//   dm_pulldown_en : R_PD from DM to ground
// The pull-up source is the 3.3 V supply (USB 2.0 specifies the 1.5 kOhm
// pull-up to 3.0-3.6 V).  Switching is instantaneous.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module afe_term_bm #(
    parameter real R_PU = 1500.0,
    parameter real R_PD = 15000.0,
    parameter real R_HS = 45.0,
    parameter real VDD  = 3.3
) (
    input  wire        dp_pullup_en,
    input  wire        dm_pullup_en,
    input  wire        hs_term_en,
    input  wire        dp_pulldown_en,
    input  wire        dm_pulldown_en,
    output reg  [63:0] dp_g, dp_i,
    output reg  [63:0] dm_g, dm_i
);
    real gp, ip, gm, im;

    always @* begin
        gp = 0.0; ip = 0.0; gm = 0.0; im = 0.0;
        if (dp_pullup_en === 1'b1)   begin gp = gp + 1.0 / R_PU; ip = ip + VDD / R_PU; end
        if (dm_pullup_en === 1'b1)   begin gm = gm + 1.0 / R_PU; im = im + VDD / R_PU; end
        if (hs_term_en === 1'b1)     begin gp = gp + 1.0 / R_HS; gm = gm + 1.0 / R_HS; end
        if (dp_pulldown_en === 1'b1) gp = gp + 1.0 / R_PD;
        if (dm_pulldown_en === 1'b1) gm = gm + 1.0 / R_PD;
        dp_g = $realtobits(gp); dp_i = $realtobits(ip);
        dm_g = $realtobits(gm); dm_i = $realtobits(im);
    end
endmodule
