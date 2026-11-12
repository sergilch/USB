* afe_cdr_tr.sp - transistor-level schematic of the CDR upper loop (afe_cdr)
*
* Same pins and behaviour as AFE/veriloga/afe_cdr.va.  Schematic, sizing and
* results: AFE/doc/cdr_schematic.md.  Devices: nch / pch of a 180 nm 1.8 V
* process (here AFE/spice/models/generic180.lib, a placeholder until the
* xh018 models are available), resistors and capacitors as ideal elements
* with the intended layout device in the comment.
*
*   CDR_DATA -> input buffer -> Alexander PD (4 flip-flops, 2 XOR)
*            -> UP / DN gated by CDR_EN -> current-steering charge pump (ICP)
*            -> loop filter C1 || (R8 + C2) on CDR_CH_OUT
*            -> V-to-I (coarse CDR_V_IN_2, fine CDR_CH_OUT, offset)
*            -> 5-stage current-starved ring VCO -> INV1..INV5 -> CLK_RX
*   INV3 output (ckpd) clocks the PD, so CLK_RX has the same polarity as the
*   PD clock and lags it by two inverters.  HS_RXD = data sample of the
*   rising edge (flip-flop A), forced to 1 while CDR_EN = 0.
*
* Shared cells (logic, flip-flops, bias, charge pump, VCO): afe_cells.sp.
*
* CDR_EN = 0: bias and V-to-I off, ring nodes clamped (CLK_RX = 0), UP / DN
* off, HS_RXD = 1, CDR_CH_OUT and the R8 / C2 midpoint reset to VDD/2
* through a switched divider.  No static current except the divider.
*
* Pin order equals afe_cdr.va:
*   CDR_DATA CDR_EN CDR_V_IN_2 CLK_RX HS_RXD CDR_CH_OUT VDD18A VSS18A

.include "afe_cells.sp"

*------------------------------------------------------------- phase detector
* Alexander PD.  Rising ckpd edge k: A = D(k), C = D(k-1), D = edge sample
* between k-1 and k (B, falling edge, retimed).  UP = C ^ D (edge equals new
* bit: clock late), DN = A ^ D (edge equals old bit: clock early), each valid
* for one bit.  Gated with en: upb / dnb are the NAND outputs.
.subckt cdr_pd din ckpd en up upb dn dnb qa vdd vss
xffa din ckpd qa vdd vss dffp
xffb din ckpd qb vdd vss dffn
xffc qa  ckpd qc vdd vss dffp
xffd qb  ckpd qd vdd vss dffp
xia qa qab vdd vss inv
xic qc qcb vdd vss inv
xid qd qdb vdd vss inv wn=1u wp=2.5u
xxu qc qcb qd qdb upx vdd vss xor2
xxd qa qab qd qdb dnx vdd vss xor2
xnu upx en upb vdd vss nand2 wn=2u wp=2.5u
xnd dnx en dnb vdd vss nand2 wn=2u wp=2.5u
xiu upb up vdd vss inv wn=1u wp=2.5u
xidn dnb dn vdd vss inv wn=1u wp=2.5u
.ends cdr_pd

*------------------------------------------------------------- top level
.subckt afe_cdr_tr cdr_data cdr_en cdr_v_in_2 clk_rx hs_rxd cdr_ch_out vdd vss
* enable
xe0 cdr_en enb vdd vss inv
xe1 enb    en  vdd vss inv wn=1u wp=2.5u
* data input buffer (CDR_DATA = RX_OUT_P, 1.8 V logic)
xb0 cdr_data db  vdd vss inv wn=1u wp=2.5u
xb1 db       din vdd vss inv wn=2u wp=5u
xbias vbn vbp en enb vdd vss cdr_bias
* phase detector, charge pump
xpd din ckpd en up upb dn dnb qa vdd vss cdr_pd
xcp up upb dn dnb cdr_ch_out vbn vbp vdd vss cdr_cp
* loop filter: C1 || (R8 + C2)
c1  cdr_ch_out vss 0.1p
* C1: MIM.  Parasitics of the node add about 30 fF.
r8  cdr_ch_out nz 2k
* R8: high-ohmic poly
xc2 vss nz vss vss nfet w=10u l=10u m=48
* C2: 40 pF NMOS capacitor (gate on nz, 48 x 10u x 10u, about 8.4 fF/um2)
* filter reset to VDD/2 while en = 0: switched divider + transmission gates
xr0 vmid_t en  vdd vdd pfet w=8u
rr0 vmid_t vmid 20k
rr1 vmid   vmid_b 20k
xr1 vmid_b enb vss vss nfet w=2u
xtr0 vmid cdr_ch_out enb en vdd vss tg wn=2u wp=4u
xtr1 vmid nz         enb en vdd vss tg wn=2u wp=4u
* VCO
xv2i cdr_v_in_2 cdr_ch_out vcp vcn vbn en enb vdd vss vco_v2i
xring n5 vcp vcn en enb vdd vss vco_ring
* clock buffer INV1..INV5: INV3 (ckpd) clocks the PD, INV5 drives CLK_RX
xinv1 n5  k1    vdd vss inv wn=1u wp=2.5u
xinv2 k1  k2    vdd vss inv wn=2u wp=5u
xinv3 k2  ckpd  vdd vss inv wn=4u wp=10u
xinv4 ckpd k4   vdd vss inv wn=2u wp=5u
xinv5 k4  clk_rx vdd vss inv wn=6u wp=15u
* retimed data: HS_RXD = qa | !en
xqa qa  qan  vdd vss inv
xo0 qan en   o0 vdd vss nand2
xo1 o0  o1   vdd vss inv wn=1u wp=2.5u
xo2 o1  hs_rxd vdd vss inv wn=3u wp=7.5u
.ends afe_cdr_tr
