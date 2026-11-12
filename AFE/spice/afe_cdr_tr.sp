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
* CDR_EN = 0: bias and V-to-I off, ring nodes clamped (CLK_RX = 0), UP / DN
* off, HS_RXD = 1, CDR_CH_OUT and the R8 / C2 midpoint reset to VDD/2
* through a switched divider.  No static current except the divider.
*
* Pin order equals afe_cdr.va:
*   CDR_DATA CDR_EN CDR_V_IN_2 CLK_RX HS_RXD CDR_CH_OUT VDD18A VSS18A

*------------------------------------------------------------- primitives
* MOS wrappers: diffusion 0.48 um long on each side
.subckt nfet d g s b w=1u l=0.18u
m0 d g s b nch w={w} l={l} ad={w*0.48u} as={w*0.48u} pd={2*w+0.96u} ps={2*w+0.96u}
.ends nfet
.subckt pfet d g s b w=1u l=0.18u
m0 d g s b pch w={w} l={l} ad={w*0.48u} as={w*0.48u} pd={2*w+0.96u} ps={2*w+0.96u}
.ends pfet

*------------------------------------------------------------- logic cells
.subckt inv a y vdd vss wn=0.5u wp=1.2u
xp y a vdd vdd pfet w={wp}
xn y a vss vss nfet w={wn}
.ends inv
.subckt nand2 a b y vdd vss wn=1u wp=1.2u
xpa y a vdd vdd pfet w={wp}
xpb y b vdd vdd pfet w={wp}
xna y a x   vss nfet w={wn}
xnb x b vss vss nfet w={wn}
.ends nand2
* transmission gate: on when gn = 1 / gp = 0
.subckt tg a b gn gp vdd vss wn=0.5u wp=1.2u
xn a gn b vss nfet w={wn}
xp a gp b vdd pfet w={wp}
.ends tg
* XOR, pass-transistor form: y = a ^ b (needs a, ab, b, bb; output not restored)
.subckt xor2 a ab b bb y vdd vss
xt0 a  y bb b  vdd vss tg wn=0.8u wp=2u
xt1 ab y b  bb vdd vss tg wn=0.8u wp=2u
.ends xor2

* Master-slave transmission-gate D flip-flop, rising edge, local clock buffer
.subckt dffp d ck q vdd vss
xc0 ck  ckb vdd vss inv wn=0.8u wp=2u
xc1 ckb cki vdd vss inv wn=0.8u wp=2u
xt1 d  m  ckb cki vdd vss tg
xi2 m  mb vdd vss inv wn=0.8u wp=2u
xi3 mb mf vdd vss inv wn=0.3u wp=0.5u
xt2 mf m  cki ckb vdd vss tg wn=0.3u wp=0.5u
xt3 mb s  cki ckb vdd vss tg
xi4 s  q  vdd vss inv wn=1.2u wp=3u
xi5 q  sf vdd vss inv wn=0.3u wp=0.5u
xt4 sf s  ckb cki vdd vss tg wn=0.3u wp=0.5u
.ends dffp
* Same, falling edge (clock phases of the latches swapped)
.subckt dffn d ck q vdd vss
xc0 ck  ckb vdd vss inv wn=0.8u wp=2u
xc1 ckb cki vdd vss inv wn=0.8u wp=2u
xt1 d  m  cki ckb vdd vss tg
xi2 m  mb vdd vss inv wn=0.8u wp=2u
xi3 mb mf vdd vss inv wn=0.3u wp=0.5u
xt2 mf m  ckb cki vdd vss tg wn=0.3u wp=0.5u
xt3 mb s  ckb cki vdd vss tg
xi4 s  q  vdd vss inv wn=1.2u wp=3u
xi5 q  sf vdd vss inv wn=0.3u wp=0.5u
xt4 sf s  cki ckb vdd vss tg wn=0.3u wp=0.5u
.ends dffn

*------------------------------------------------------------- bias
* Constant-gm (beta multiplier) reference, I0 = 10 uA nominal, power-down by
* en / enb, start-up through MST.  vbn: NMOS mirror gate (I0 per 2u/1u),
* vbp: PMOS mirror gate (I0 per 4u/1u).
.subckt cdr_bias vbn vbp en enb vdd vss
xm1  vbn vbn vss  vss nfet w=2u l=1u
xm2  vbp vbn xs   vss nfet w=2u l=1u m=4
rb   xs  vss 10k
* RB: high-ohmic poly, 2 um wide
xm3  vbp vbp vdd  vdd pfet w=4u l=1u
xm4  vbn vbp vdd  vdd pfet w=4u l=1u
* start-up: st high while vbn is low, XST then pulls current out of vbp
xs1  st  vss vdd  vdd pfet w=0.5u l=8u
xs2  st  vbn vss  vss nfet w=1u l=0.5u
xst  vbp st  vbn  vss nfet w=1u l=0.5u
* power-down: vbp -> VDD, vbn -> 0, start-up off
xpd1 vbp en  vdd  vdd pfet w=2u
xpd2 vbn enb vss  vss nfet w=2u
xpd3 st  enb vss  vss nfet w=1u
.ends cdr_bias

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

*------------------------------------------------------------- charge pump
* Current steering: the sources always conduct ICP = 5 * I0 = 50 uA; the
* switch pairs steer it to the filter (out) or to vrep.  An OTA follower
* holds vrep at V(out), so the sources see the same voltage either way
* (no charge sharing when a switch closes).
.subckt cdr_cp up upb dn dnb out vbn vbp vdd vss
xpsrc sp  vbp vdd vdd pfet w=4u l=1u m=5
xpsw  out upb sp vdd pfet w=4u
xpdmp vrep up sp vdd pfet w=4u
xnsrc sn  vbn vss vss nfet w=2u l=1u m=5
xnsw  out dn  sn vss nfet w=2u
xndmp vrep dnb sn vss nfet w=2u
* vrep follower: NMOS pair, PMOS mirror, tail I0
xot   ot  vbn vss  vss nfet w=2u l=1u
xo1   o1  out ot   vss nfet w=8u l=0.5u
xo2   vrep vrep ot vss nfet w=8u l=0.5u
xo3   o1  o1  vdd  vdd pfet w=4u l=0.5u
xo4   vrep o1 vdd  vdd pfet w=4u l=0.5u
cvr   vrep vss 1p
.ends cdr_cp

*------------------------------------------------------------- VCO
* Current-starved inverter stage
.subckt vco_stage in out vcp vcn vdd vss
xps sp  vcp vdd vdd pfet w=10u l=0.36u
xpi out in  sp  vdd pfet w=5u
xni out in  sn  vss nfet w=2u
xns sn  vcn vss vss nfet w=4u l=0.36u
.ends vco_stage

* V-to-I: reference current into the PMOS diode MPD
*   I = I(MC, coarse, CDR_V_IN_2) + I(MF, fine, CDR_CH_OUT) + I(MOFF, offset)
* MC / MF source-degenerated (RC / RF) for a linear tuning curve.  The PLL
* VCO must be the same cell (V-to-I + ring), with its fine input on 0.9 V.
.subckt vco_v2i vco vfi vcp vcn vbn en enb vdd vss
xmpd vcp vcp vdd vdd pfet w=10u l=0.36u m=2
xmc  vcp vco xc vss nfet w=20u l=0.36u
rc   xc  ng  5k
xmf  vcp vfi xf vss nfet w=20u l=0.36u
rf   xf  ng  3.2k
xsw  ng  en  vss vss nfet w=40u
xmof vcp vbn vss vss nfet w=2u l=1u m=16
* PMOS mirror -> NMOS diode for the starving NMOS gates
xmpm vcn vcp vdd vdd pfet w=10u l=0.36u m=2
xmnd vcn vcn vss vss nfet w=4u l=0.36u m=2
* power-down
xpd1 vcp en  vdd vdd pfet w=4u
xpd2 vcn enb vss vss nfet w=4u
.ends vco_v2i

* 5-stage ring.  en = 0: stage outputs clamped alternately (n1, n3, n5 high,
* n2, n4 low) with the starving devices off, so the ring stops with n5 = 1
* and CLK_RX = 0; at en = 1 stage 1 sees the inconsistent input first and the
* ring starts at once.  Every node carries the same load (INV1-sized), the
* real INV1 on n5 and dummies on n1..n4.
.subckt vco_ring n5 vcp vcn en enb vdd vss
xs1 n5 n1 vcp vcn vdd vss vco_stage
xs2 n1 n2 vcp vcn vdd vss vco_stage
xs3 n2 n3 vcp vcn vdd vss vco_stage
xs4 n3 n4 vcp vcn vdd vss vco_stage
xs5 n4 n5 vcp vcn vdd vss vco_stage
xc1 n1 en  vdd vdd pfet w=0.5u
xc2 n2 enb vss vss nfet w=0.5u
xc3 n3 en  vdd vdd pfet w=0.5u
xc4 n4 enb vss vss nfet w=0.5u
xc5 n5 en  vdd vdd pfet w=0.5u
xd1 n1 d1 vdd vss inv wn=1u wp=2.5u
xd2 n2 d2 vdd vss inv wn=1u wp=2.5u
xd3 n3 d3 vdd vss inv wn=1u wp=2.5u
xd4 n4 d4 vdd vss inv wn=1u wp=2.5u
.ends vco_ring

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
