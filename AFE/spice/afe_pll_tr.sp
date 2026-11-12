* afe_pll_tr.sp - transistor-level schematic of the PLL (lower loop, afe_pll)
*
* Same pins and behaviour as AFE/veriloga/afe_pll.va.  Schematic, sizing and
* results: AFE/doc/pll_schematic.md.  Devices: nch / pch of a 180 nm 1.8 V
* process (AFE/spice/models/generic180.lib, a placeholder until the xh018
* models are available), resistors and capacitors as ideal elements with the
* intended layout device in the comment.  Shared cells: afe_cells.sp.
*
*   CDR_FREF -> XF0 -> XF2 (ref_i) -> PFD (2 TSPC flip-flops, delayed AND reset)
*            -> UP / DN -> current-steering charge pump (ICP = 2 * I0 = 20 uA)
*            -> loop filter C4 || (R2 + C3) on CDR_CH_OUT_PLL
*            -> VCO = the CDR's VCO cell (vco_v2i + vco_ring + INV1):
*               coarse input = CDR_CH_OUT_PLL, fine input = VDD/2 (vref)
*            -> INV1..INV5 -> CLK_BIT_A;  INV3 (ckd) -> divider
*   divider: /5 prescaler (3 flip-flops, NOR feedback, 96 MHz) -> /4 or /5
*            (3 flip-flops, AOI21 feedback; /5 when REFSEL = 00) -> fb -> PFD
*            N = 25 for REFSEL 00 (19.2 MHz), 20 otherwise (24 MHz; 26 MHz
*            and 11 are flagged by the digital, refsel_err)
*   CDR_FREF -> XF0 -> XF1 -> REF_DIG, always on (not gated by PLL_EN)
*
* PLL_EN = 0: bias, V-to-I and vref off, ring clamped (CLK_BIT_A = 0), PFD
* held in reset, CDR_CH_OUT_PLL and the R2 / C3 midpoint discharged to VSS
* (the VCO restarts from the bottom of its range, as in afe_pll.va).
*
* Pin order equals afe_pll.va:
*   CDR_FREF PLL_EN REFSEL1 REFSEL0 CLK_BIT_A REF_DIG CDR_CH_OUT_PLL VDD18A VSS18A

.include "afe_cells.sp"

*------------------------------------------------------------- local cells
.subckt nor2 a b y vdd vss wn=0.5u wp=2.4u
xpa x a vdd vdd pfet w={wp}
xpb y b x   vdd pfet w={wp}
xna y a vss vss nfet w={wn}
xnb y b vss vss nfet w={wn}
.ends nor2
* y = !(a | (b & c))
.subckt aoi21 a b c y vdd vss
xpa x  a vdd vdd pfet w=2.4u
xpb y  b x   vdd pfet w=2.4u
xpc y  c x   vdd pfet w=2.4u
xna y  a vss vss nfet w=0.5u
xnb y  b z   vss nfet w=1u
xnc z  c vss vss nfet w=1u
.ends aoi21

* TSPC PFD flip-flop (D = 1): rising ck -> qb falls (UP / DN active);
* rst = 1 -> qb high.  The precharge path XP1 / XP2 is cut while rst = 1,
* so a reset that arrives while ck is low does not fight it.
.subckt pfd_ff ck rst qb vdd vss
xp2 p1 rst vdd vdd pfet w=2u
xp1 n1 ck  p1  vdd pfet w=2u
xn2 n1 rst vss vss nfet w=1u
xp3 qb n1  vdd vdd pfet w=2u
xn4 qb ck  x   vss nfet w=2u
xn5 x  n1  vss vss nfet w=2u
.ends pfd_ff

* Phase-frequency detector: UP on ref, DN on fb, reset = (UP & DN) delayed
* by NAND + 2 inverters (about 200 ps, no dead zone), forced while en = 0.
.subckt pll_pfd ref fb en up upb dn dnb vdd vss
xfu ref rst qu vdd vss pfd_ff
xfd fb  rst qd vdd vss pfd_ff
xiu qu up  vdd vss inv wn=1u wp=2.5u
xiub up upb vdd vss inv wn=1u wp=2.5u
xid qd dn  vdd vss inv wn=1u wp=2.5u
xidb dn dnb vdd vss inv wn=1u wp=2.5u
xr0 up dn ra vdd vss nand2
xr1 ra rb vdd vss inv
xr2 rb rc vdd vss inv
xr3 rc en rst vdd vss nand2
.ends pll_pfd

* Feedback divider.  /5: A <- NOR(B, C), B <- A, C <- B (states 000, 100,
* 110, 011, 001; self-starting).  Second stage on A (96 MHz): D <- AOI21(E,
* F, sel5), E <- D, F <- E: /5 with sel5 = 1, /4 (D, E as a Johnson pair)
* with sel5 = 0.  fb = D.
.subckt pll_div ck sel5 fb vdd vss
xa da ck qa vdd vss dffp
xb qa ck qb vdd vss dffp
xc qb ck qc vdd vss dffp
xna qb qc da vdd vss nor2
xd dd qa fb vdd vss dffp
xe fb qa qe vdd vss dffp
xf qe qa qf vdd vss dffp
xnd qe qf sel5 dd vdd vss aoi21
.ends pll_div

*------------------------------------------------------------- top level
.subckt afe_pll_tr cdr_fref pll_en refsel1 refsel0 clk_bit_a ref_dig cdr_ch_out_pll vdd vss
* enable
xe0 pll_en enb vdd vss inv
xe1 enb    en  vdd vss inv wn=1u wp=2.5u
* reference: REF_DIG always on, ref_i into the PFD
xf0 cdr_fref fr  vdd vss inv wn=1u wp=2.5u
xf1 fr   ref_dig vdd vss inv wn=2u wp=5u
xf2 fr   ref_i   vdd vss inv wn=1u wp=2.5u
* divider select: /25 for REFSEL = 00
xs0 refsel1 refsel0 sel5 vdd vss nor2
xbias vbn vbp en enb vdd vss cdr_bias
xpfd ref_i fb en up upb dn dnb vdd vss pll_pfd
xcp up upb dn dnb cdr_ch_out_pll vbn vbp vdd vss cdr_cp n=2
* loop filter: C4 || (R2 + C3)
c4  cdr_ch_out_pll vss 1.53p
* C4: MIM
r2  cdr_ch_out_pll nz 34.5k
* R2: high-ohmic poly
xc3 vss nz vss vss nfet w=10u l=10u m=18
* C3: 15.1 pF NMOS capacitor (18 x 10u x 10u)
* discharge while en = 0
xd0 cdr_ch_out_pll enb vss vss nfet w=2u
xd1 nz             enb vss vss nfet w=2u
* fine-input reference VDD/2 for the shared VCO (the CDR's fine node is reset
* to the same VDD/2, so both VCOs sit at the same point of their curve)
xq0 vq_t enb vdd vdd pfet w=8u
rq0 vq_t vref 100k
rq1 vref vq_b 100k
xq1 vq_b en  vss vss nfet w=2u
xcq vss vref vss vss nfet w=10u l=10u m=1
* VCO (identical to the CDR's)
xv2i cdr_ch_out_pll vref vcp vcn vbn en enb vdd vss vco_v2i
xring n5 vcp vcn en enb vdd vss vco_ring
* clock buffer INV1..INV5 (INV1 as in the CDR): INV3 (ckd) clocks the divider
xinv1 n5  k1  vdd vss inv wn=1u wp=2.5u
xinv2 k1  k2  vdd vss inv wn=2u wp=5u
xinv3 k2  ckd vdd vss inv wn=4u wp=10u
xinv4 ckd k4  vdd vss inv wn=4u wp=10u
xinv5 k4  clk_bit_a vdd vss inv wn=12u wp=30u
xdiv ckd sel5 fb vdd vss pll_div
.ends afe_pll_tr
