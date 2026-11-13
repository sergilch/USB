* afe_cells.sp - cells shared by the transistor-level AFE netlists
*
* Included by afe_cdr_tr.sp (CDR upper loop), afe_pll_tr.sp (PLL, lower
* loop) and afe_receiver_tr.sp (HS receiver, squelch, disconnect).  The VCO (vco_v2i + vco_ring + an INV1-sized load on n5) must be the
* same cell in both, so the CDR VCO free-runs at the PLL frequency (risk R3):
* change it here only, and rerun both testbenches.  Devices: nch / pch (and
* nch33 / pch33, 3.3 V) from
* the model library the testbench includes (AFE/spice/models/generic180.lib
* for now).  Documentation: AFE/doc/cdr_schematic.md, AFE/doc/pll_schematic.md.

*------------------------------------------------------------- primitives
* MOS wrappers: diffusion 0.48 um long on each side
.subckt nfet d g s b w=1u l=0.18u
m0 d g s b nch w={w} l={l} ad={w*0.48u} as={w*0.48u} pd={2*w+0.96u} ps={2*w+0.96u}
.ends nfet
.subckt pfet d g s b w=1u l=0.18u
m0 d g s b pch w={w} l={l} ad={w*0.48u} as={w*0.48u} pd={2*w+0.96u} ps={2*w+0.96u}
.ends pfet
* 3.3 V thick-oxide devices (L >= 0.35 um), diffusion 0.6 um: only the
* receiver's input stages on RX_VDD use them
.subckt nfet33 d g s b w=1u l=0.35u
m0 d g s b nch33 w={w} l={l} ad={w*0.6u} as={w*0.6u} pd={2*w+1.2u} ps={2*w+1.2u}
.ends nfet33
.subckt pfet33 d g s b w=1u l=0.35u
m0 d g s b pch33 w={w} l={l} ad={w*0.6u} as={w*0.6u} pd={2*w+1.2u} ps={2*w+1.2u}
.ends pfet33

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

*------------------------------------------------------------- charge pump
* Current steering: the sources always conduct ICP = n * I0 (CDR: n = 5,
* 50 uA; PLL: n = 2, 20 uA); the switch pairs steer it to the filter (out)
* or to vrep.  An OTA follower
* holds vrep at V(out), so the sources see the same voltage either way
* (no charge sharing when a switch closes).
.subckt cdr_cp up upb dn dnb out vbn vbp vdd vss n=5
xpsrc sp  vbp vdd vdd pfet w=4u l=1u m={n}
xpsw  out upb sp vdd pfet w=4u
xpdmp vrep up sp vdd pfet w=4u
xnsrc sn  vbn vss vss nfet w=2u l=1u m={n}
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
