* afe_receiver_tr.sp - transistor-level schematic of the HS receiver, squelch
*                      and disconnect detector (afe_receiver)
*
* Same pins and behaviour as afe_receiver in AFE/veriloga/afe_receiver.va.
* Schematic, sizing and results: AFE/doc/receiver_schematic.md.  Devices:
* 180 nm, nch / pch (1.8 V core) and nch33 / pch33 (3.3 V thick oxide) from
* AFE/spice/models/generic180.lib (placeholder for the xh018 models);
* resistors and capacitors are ideal elements with the intended layout device
* in the comment.  Shared cells: afe_cells.sp.
*
* Two supply domains, as in the model:
*   RX_VDD  (3.3 V)  input stages only: thick-oxide PMOS pairs (the HS line
*                    sits at 0 .. 0.4 V, common mode -50 .. 500 mV) into poly
*                    resistor loads, so their outputs stay below 0.6 V
*   RX_VDDO (1.8 V)  bias, comparators with hysteresis, timers, logic and the
*                    output drivers (proposed 1.8 V output stage, Q8): the
*                    outputs swing 0 .. 1.8 V.  RX_VDDO = 3.3 V is not
*                    supported by this netlist (core devices)
*
*   bias      I0 = V(RX_VREF) / RB (20 uA at 1.2 V): OTA + PMOS pass device;
*             every threshold below is I0 times a resistor of the same poly,
*             so it is a ratio of RX_VREF
*   HS RX     PMOS pair (200 uA, 3 kOhm loads, gain about 2.5) -> rx_cmp
*             (cross-coupled loads give the hysteresis) -> gating -> RX_OUT_P/N
*   squelch   2 differential-difference preamps (|DP - DM| > I0 * RSQ,
*             one per polarity) -> rx_cmp -> OR = act_raw -> bridge timer
*             (3 ns) -> env -> on timer (6 ns) / off timer (10 ns) ->
*             SR latch -> SQUELCH_A = !(act_f & on)
*   disconnect same preamps with I0 * RDISC -> OR -> 4 ns timer
*             (immediate fall) -> DISC_A = dsc & on
*   UVLO      RX_VDD / 5.74 against I0 * RUV (0.5 V): on = RX_EN & (RX_VDD
*             above about 2.95 V)
* Off (RX_EN = 0 or RX_VDD low): RX_OUT_P = 0, RX_OUT_N = 1, SQUELCH_A = 1,
* DISC_A = 0.  RX_EN = 0 also switches the bias off (no supply current).
*
* Pin order equals afe_receiver.va:
*   RX_IN_P RX_IN_N RX_EN RX_VREF RX_OUT_P RX_OUT_N SQUELCH_A DISC_A RX_VDD RX_GND RX_VDDO

.include "afe_cells.sp"

*------------------------------------------------------------- local cells
.subckt rx_nor2 a b y vdd vss wn=0.5u wp=2.4u
xpa x a vdd vdd pfet w={wp}
xpb y b x   vdd pfet w={wp}
xna y a vss vss nfet w={wn}
xnb y b vss vss nfet w={wn}
.ends rx_nor2
.subckt rx_nor3 a b c y vdd vss wn=0.5u wp=3.6u
xpa x1 a vdd vdd pfet w={wp}
xpb x2 b x1  vdd pfet w={wp}
xpc y  c x2  vdd pfet w={wp}
xna y a vss vss nfet w={wn}
xnb y b vss vss nfet w={wn}
xnc y c vss vss nfet w={wn}
.ends rx_nor3
.subckt nand3 a b c y vdd vss wn=1.5u wp=1.2u
xpa y a vdd vdd pfet w={wp}
xpb y b vdd vdd pfet w={wp}
xpc y c vdd vdd pfet w={wp}
xna y a x1  vss nfet w={wn}
xnb x1 b x2 vss nfet w={wn}
xnc x2 c vss vss nfet w={wn}
.ends nand3

* Bias, RX_VDDO domain.  OTA (XO1..XO4, tail XO0 from the crude RT / XT1
* bias) drives the pass device XM0 so that V(fb) = V(RX_VREF): I0 = VREF / RB.
* vbp18 (= the OTA output) is the gate of every 1.8 V PMOS current source
* (8u/1u = I0).  XM1 (4 I0) -> XN33D; XN33M sinks 4 I0 from the RX_VDD diode
* XP33D (4 x 16u/2u), which gives vbp33 for the 3.3 V current sources (pch33
* 16u/2u = I0, long for matching across the large Vds differences): the 4x
* diode current charges the vbp33 gates in about 70 ns.  en18 = 0: OTA and
* crude bias off, vbp18 -> RX_VDDO, n33 -> 0, vbp33 -> RX_VDD (en33 = 0).
* No start-up circuit needed: the OTA tail comes from RT, not from I0.
.subckt rx_bias vref en18 enb18 en33 vbp18 vbp33 vdd vddo vss
xt0 tt  enb18 vddo vddo pfet w=1u
rt  tt  vbt 40k
* RT: high-ohmic poly
xt1 vbt vbt vss vss nfet w=2u l=1u
xo0 ot  vbt vss vss nfet w=2u l=1u
xo1 o1  fb   ot vss nfet w=4u l=0.5u
xo2 vbp18 vref ot vss nfet w=4u l=0.5u
xo3 o1  o1  vddo vddo pfet w=4u l=0.5u
xo4 vbp18 o1 vddo vddo pfet w=4u l=0.5u
cc  vbp18 vddo 0.3p
* CC: MIM, OTA compensation
xm0 fb  vbp18 vddo vddo pfet w=8u l=1u
rb  fb  vss 60k
* RB: high-ohmic poly, same type as RSQ / RDISC / RUV (thresholds track)
xpd0 vbp18 en18 vddo vddo pfet w=4u
* 3.3 V current-source gate
xm1 n33 vbp18 vddo vddo pfet w=8u l=1u m=4
xn33d n33 n33 vss vss nfet33 w=4u l=2u m=4
xn33m vbp33 n33 vss vss nfet33 w=4u l=2u m=4
xp33d vbp33 vbp33 vdd vdd pfet33 w=16u l=2u m=4
xpd1 n33 enb18 vss vss nfet w=2u
xpd2 vbp33 en33  vdd vdd pfet33 w=4u
.ends rx_bias

* Comparator with hysteresis, RX_VDDO domain (Allstot / Baker): PMOS pair
* XC1 / XC2 (inputs 0 .. 0.6 V), diode loads XC3 / XC4, cross-coupled XC5 /
* XC6 (wider than the diodes: hysteresis), output stage XC7..XC10 mirrors the
* two branch currents into out.  out = 1 when V(g2) > V(g1) (plus / minus
* half the hysteresis).  Tail mt * I0.  enb = 1 pulls out, d1 and d2 low
* (tail off; no charge left on d1 / d2 to keep the output mirror conducting).
.subckt rx_cmp g1 g2 out vbp18 enb vddo vss mt=2 wi=6u wd=1u wx=1.2u wo=2u
xc0 s  vbp18 vddo vddo pfet w=8u l=1u m={mt}
xc1 d1 g1 s s pfet w={wi} l=0.25u
xc2 d2 g2 s s pfet w={wi} l=0.25u
xc3 d1 d1 vss vss nfet w={wd} l=0.25u
xc4 d2 d2 vss vss nfet w={wd} l=0.25u
xc5 d1 d2 vss vss nfet w={wx} l=0.25u
xc6 d2 d1 vss vss nfet w={wx} l=0.25u
xc7 o7 d1 vss vss nfet w={wo} l=0.25u
xc8 out d2 vss vss nfet w={wo} l=0.25u
xc9 o7 o7 vddo vddo pfet w={2.5*wo}
xc10 out o7 vddo vddo pfet w={2.5*wo}
xc11 out enb vss vss nfet w=0.5u
xc12 d1  enb vss vss nfet w=0.3u
xc13 d2  enb vss vss nfet w=0.3u
.ends rx_cmp

* Differential-difference preamp, RX_VDD domain: pair A (in1, in2) and pair B
* (rl, rh), each a pch33 pair with its own tail (mt * I0) and n-well tied to
* its source.  x = drains of in1 and rl, y = drains of in2 and rh, loads RL.
* I(x) - I(y) ~ gm * ((in2 - in1) + (rh - rl)): y > x when in1 - in2 >
* rh - rl.  Pair B sits at a fixed common mode; pairs with an ideal tail are
* insensitive to it.
.subckt rx_dda in1 in2 rl rh x y vbp33 vdd vss mt=1 w=2u l=1u rld=10k
xta sa vbp33 vdd vdd pfet33 w=16u l=2u m={mt}
xa1 x in1 sa sa pfet33 w={w} l={l}
xa2 y in2 sa sa pfet33 w={w} l={l}
xtb sb vbp33 vdd vdd pfet33 w=16u l=2u m={mt}
xb1 x rl sb sb pfet33 w={w} l={l}
xb2 y rh sb sb pfet33 w={w} l={l}
r1 x vss {rld}
r2 y vss {rld}
* R1 / R2: poly
.ends rx_dda

* Ramp timer, RX_VDDO domain: while in = 1 the source XT0 (I0) charges C;
* in = 0 resets it at once.  out = 1 once the ramp passes the inverter
* threshold (about VDDO / 2): t = C * VDDO / 2 / I, I = I0 * wi / 8u.
* rst = 1 (receiver off) holds the ramp at 0 V: no floating inverter input.
.subckt rx_tmr in out rst vbp18 vddo vss c=50f wi=8u
xin in inb vddo vss inv
xt0 ts vbp18 vddo vddo pfet w={wi} l=1u
xt1 r  inb  ts   vddo pfet w=2u
xt2 r  inb  vss  vss  nfet w=2u
xt3 r  rst  vss  vss  nfet w=0.5u
ct  r  vss {c}
* CT: MIM
xi0 r  ob  vddo vss inv
xi1 ob out vddo vss inv
.ends rx_tmr

*------------------------------------------------------------- top level
.subckt afe_receiver_tr rx_in_p rx_in_n rx_en rx_vref rx_out_p rx_out_n squelch_a disc_a
+ rx_vdd rx_gnd rx_vddo
* enable: RX_VDDO domain, level shifter to RX_VDD
xe0 rx_en enb18 rx_vddo rx_gnd inv
xe1 enb18 en18  rx_vddo rx_gnd inv wn=1u wp=2.5u
xl0 lsb en18  rx_gnd rx_gnd nfet33 w=2u
xl1 en33 enb18 rx_gnd rx_gnd nfet33 w=2u
xl2 lsb en33 rx_vdd rx_vdd pfet33 w=1u l=0.5u
xl3 en33 lsb rx_vdd rx_vdd pfet33 w=1u l=0.5u
xbias rx_vref en18 enb18 en33 vbp18 vbp33 rx_vdd rx_vddo rx_gnd rx_bias

* ---- HS receiver: XA pair (3.3 V) -> comparator with hysteresis
xa0 sa vbp33 rx_vdd rx_vdd pfet33 w=16u l=2u m=10
xa1 xa rx_in_p sa sa pfet33 w=24u l=0.35u
xa2 ya rx_in_n sa sa pfet33 w=24u l=0.35u
ra1 xa rx_gnd 3k
ra2 ya rx_gnd 3k
* RA1 / RA2: poly
xhs xa ya hsc vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=5 wd=2u wx=2.55u wo=4u
xh0 hsc hsb rx_vddo rx_gnd inv wn=1u wp=2.5u
xh1 hsb hs  rx_vddo rx_gnd inv wn=1u wp=2.5u
xh2 hs on pn rx_vddo rx_gnd nand2 wn=2u wp=2.5u
xh3 hsb onb nn rx_vddo rx_gnd rx_nor2 wn=1u wp=5u
xh4 pn rx_out_p rx_vddo rx_gnd inv wn=2u wp=5u
xh5 nn rx_out_n rx_vddo rx_gnd inv wn=2u wp=5u

* ---- threshold references: I0 into a poly string (one current, ratios only)
*   rdl 0.1125 V, rsl 0.1425 V, rsh 0.2475 V, rdh 0.6725 V
* RSQ = RR2 = 5.25k (105 mV), RDISC = RR1 + RR2 + RR3 = 28.0k (560 mV).  The
* preamps and comparators add about +4 mV / +3 %: static thresholds about
* 110 / 575 mV.  On alternating 480 Mbit/s data the squelch releases about
* 30 mV higher (preamp recovery every bit), so 105 mV centres both the static
* and the dynamic threshold in the USB window 100 .. 150 mV
* (AFE/doc/receiver_schematic.md 4.1)
xr0 rt0 vbp33 rx_vdd rx_vdd pfet33 w=16u l=2u
rr0 rt0 rdh 21.25k
rr1 rdh rsh 21.25k
rr2 rsh rsl 5.25k
rr3 rsl rdl 1.5k
rr4 rdl rx_gnd 5.625k
cr0 rdh rx_gnd 0.5p
cr1 rsh rx_gnd 0.5p
cr2 rsl rx_gnd 0.5p
cr3 rdl rx_gnd 0.5p
* CR0..CR3: MIM decoupling

* ---- squelch: DP - DM > RSQ * I0 (sp) or DM - DP > RSQ * I0 (sn); strong-
*      inversion pairs (Vov 0.22 V, linear past the threshold) into 3 kOhm:
*      tau about 0.1 ns, so they recover from the opposite polarity in a bit
xsp rx_in_p rx_in_n rsl rsh xsp ysp vbp33 rx_vdd rx_gnd rx_dda mt=5 w=16u l=0.5u rld=3k
xsn rx_in_n rx_in_p rsl rsh xsn ysn vbp33 rx_vdd rx_gnd rx_dda mt=5 w=16u l=0.5u rld=3k
xcsp xsp ysp sqp vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=4 wi=3u wx=1u
xcsn xsn ysn sqn vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=4 wi=3u wx=1u
* OR with a low switching point (strong NMOS, about 0.5 V): at ss the comparator
* pulses on alternating data are 0.5 ns runts that reach only 1.0 .. 1.2 V
xs0 sqp sqn actb rx_vddo rx_gnd rx_nor2 wn=2u wp=1u
xs1 actb act rx_vddo rx_gnd inv
* bridge: env falls 3 ns after the last activity
xtbr actb bt enb18 vbp18 rx_vddo rx_gnd rx_tmr c=60f
xs2 bt env rx_vddo rx_gnd inv
* release after 6 ns of env, assertion after 10 ns without it (+ 3 ns bridge)
xton env  son enb18 vbp18 rx_vddo rx_gnd rx_tmr c=125f
xtof bt   sof enb18 vbp18 rx_vddo rx_gnd rx_tmr c=190f
* SR latch: son sets act_f; sof or !on resets it
xs3 sof onb actf_b actf rx_vddo rx_gnd rx_nor3
xs4 son actf actf_b rx_vddo rx_gnd rx_nor2
xs5 actf on sqn_o rx_vddo rx_gnd nand2
xs6 sqn_o sq1 rx_vddo rx_gnd inv
xs7 sq1 squelch_a rx_vddo rx_gnd inv wn=1u wp=2.5u

* ---- disconnect: |DP - DM| > RDISC * I0 for 4 ns; pairs with Vov 0.56 V
*      (linear past 575 mV)
xdp rx_in_p rx_in_n rdl rdh xdp ydp vbp33 rx_vdd rx_gnd rx_dda mt=2 w=1u l=0.5u rld=7.5k
xdn rx_in_n rx_in_p rdl rdh xdn ydn vbp33 rx_vdd rx_gnd rx_dda mt=2 w=1u l=0.5u rld=7.5k
xcdp xdp ydp dsp vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=4 wi=3u wx=1u
xcdn xdn ydn dsn vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=4 wi=3u wx=1u
xd0 dsp dsn dscb rx_vddo rx_gnd rx_nor2
xd1 dscb dsc rx_vddo rx_gnd inv
xtd dsc dsf enb18 vbp18 rx_vddo rx_gnd rx_tmr c=60f
xd2 dsf on dn_o rx_vddo rx_gnd nand2
xd3 dn_o disc_a rx_vddo rx_gnd inv wn=1u wp=2.5u

* ---- UVLO: RX_VDD * 100k / 574k against I0 * 25k = 0.5 V (+ comparator
*      offset) -> off below about 2.93 V, on above about 2.96 V
* switch at the top (XU0, gate lsb = !en in the RX_VDD domain), so vdiv is
* 0 V while off and never above 0.6 V: it drives a core-device gate
xu0 ut lsb rx_vdd rx_vdd pfet33 w=1u
ru1 ut vdiv 474k
ru2 vdiv rx_gnd 100k
* RU1 / RU2: high-ohmic poly
xu1 vuv vbp18 rx_vddo rx_vddo pfet w=8u l=1u
ruv vuv rx_gnd 25k
xcu vuv vdiv pok vbp18 enb18 rx_vddo rx_gnd rx_cmp mt=1 wx=1.05u
* ready: 130 ns after RX_EN (bias and preamps settled), I0 / 10 into 0.3 pF
xtrdy en18 rdy enb18 vbp18 rx_vddo rx_gnd rx_tmr c=0.3p wi=0.8u
xg0 pok rdy en18 onb rx_vddo rx_gnd nand3
xg1 onb on rx_vddo rx_gnd inv
.ends afe_receiver_tr
