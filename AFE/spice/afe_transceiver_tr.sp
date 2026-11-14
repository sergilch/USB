* afe_transceiver_tr.sp - transistor-level schematic of the USB 2.0 line
*                         transceiver (afe_transceiver): HS current driver,
*                         FS / LS drivers and receivers, terminations
*
* Same pins and behaviour as afe_transceiver in AFE/veriloga/afe_transceiver.va.
* Schematic, sizing and results: AFE/doc/transceiver_schematic.md.  Devices:
* 180 nm, nch / pch (1.8 V core) and nch33 / pch33 (3.3 V thick oxide) from
* AFE/spice/models/generic180.lib (placeholder for the xh018 models);
* resistors and capacitors are ideal elements with the intended layout device
* in the comment.  Shared cells: afe_cells.sp.
*
* Two supply domains, as in the model:
*   VDD33 (3.3 V)  everything that touches DP / DM: HS current source and
*                  steering switches, FS / LS output stages, terminations and
*                  pulls, receivers, bias, UVLO (thick-oxide devices)
*   VDD18 (1.8 V)  input logic, HS switch pre-drivers (they swing the pch33
*                  switch gates 0 .. 1.8 V: no level shifter in the 480 Mbit/s
*                  path, Q8), the TX_EN ready timer, receiver output gating and
*                  output drivers (outputs 0 .. VDD18)
*
*   bias      OTA forces V(fb) = V(TX_VREF) on RREF = 12 kOhm: 100 uA through
*             a replica of the HS source (2 of its 356 units) and of its
*             switches; vbp = gate of every pch33 source (10/1 = 50 uA),
*             nb = gate of the nch33 sinks (5/1 = 50 uA)
*   HS TX     XS (356 units, 17.8 mA) -> XE enable switch (TX_EN) -> cs ->
*             steering XSP (DP) / XSN (DM) / XSD (dump, 22.5 Ohm).  TX_EN
*             starts the current into the dump; a ready timer (about 18 ns,
*             the model's t_en) then hands it to XSP / XSN.  TX_IN_P = TX_IN_N
*             opens both (half / half, as the model)
*   FS / LS   per wire a pch33 / nch33 push-pull and RS 26 Ohm (34 Ohm in
*             total); Miller capacitors CM from the drain to each gate set the
*             slew rate: turn-on through a current source (LS about 25 uA,
*             FS 350 uA more, mirror ratios of vbp / nb), turn-off at once
*             (break before make)
*   RX        RXDP_A / RXDM_A: CMOS Schmitt triggers on VDD33 (1.26 / 1.60 V);
*             RXRCV_A: rail-to-rail comparator (pch33 + nch33 pairs) with
*             switched-current hysteresis; all three down-shifted to VDD18
*   terms     1.5 kOhm pull-up (pch33 switch + 1.405 kOhm), 45 Ohm HS
*             terminations (nch33 + 41.6 Ohm), 15 kOhm pull-downs (nch33 +
*             14 kOhm), gates level-shifted from the 1.8 V enables
*   UVLO      VDD33 divider against TX_VREF: pok = VDD33 above about 2.94 V
*             (off below 2.86 V).  !pok: no HS current, FS driver off,
*             receivers isolated (RXDP_A = RXDM_A = 0, RXRCV_A = 1)
* TX_VREF must be present (1.2 V) for anything to work: it sets every bias
* current (Q9, the model's bias_mode 1).  TX_I_5U is not used (1 GOhm to GND,
* as bias_mode 0).  TX_CAP_P / TX_CAP_N connect to DP / DM through 1 TOhm
* (open, as the model's default r_cap; Q10).
*
* Pin order equals afe_transceiver.va:
*   TX_IN_P TX_IN_N TX_EN TX_I_5U TX_VREF TX_CAP_P TX_CAP_N
*   FS_OE_A FS_DAT_A FS_SE0_A FS_LS_A FS_RX_EN_A RXRCV_A RXDP_A RXDM_A
*   DP_PULLUP_EN_A HS_TERM_EN_A PD_EN_A0 PD_EN_A1 DP DM VDD33 VDD18 GND

.include "afe_cells.sp"

*------------------------------------------------------------- local cells
* 3.3 V inverter (thick oxide)
.subckt inv33 a y vdd vss wn=1u wp=2.5u
xp y a vdd vdd pfet33 w={wp}
xn y a vss vss nfet33 w={wn}
.ends inv33
* 1.8 V -> 3.3 V level shifter: y = a, yb = !a (VDD33); a from VDD18 logic
.subckt ls_up a y yb vddl vdd vss
xi a ab vddl vss inv
xl0 yb a  vss vss nfet33 w=2u
xl1 y  ab vss vss nfet33 w=2u
xl2 yb y  vdd vdd pfet33 w=1u l=0.5u
xl3 y  yb vdd vdd pfet33 w=1u l=0.5u
.ends ls_up
* 3.3 V -> 1.8 V: inverter on VDDL built from thick-oxide devices (its gates
* take 0 .. 3.3 V), y = !a, 0 .. VDDL
.subckt ls_dn a y vddl vss
xp y a vddl vddl pfet33 w=2u
xn y a vss  vss  nfet33 w=1u
.ends ls_dn
* HS switch pre-driver: the output falls at once (xn1: turns the steering
* switch on) and rises at the mirror current mp x 50 uA (xp2, gate pbs: turns
* it off slowly), so the switch that turns on always leads (make before
* break) and the turn-off ramp, set by the reference current, sets the line
* edge.
.subckt sinv a y pbs vdd vss mp=18
xp1 y  a   pp  vdd pfet w=24u
xp2 pp pbs vdd vdd pfet w=5u l=0.36u m={mp}
xn1 y  a   vss vss nfet w=6u
.ends sinv
* OAI21: y = !(c & (a | b))
.subckt oai21 a b c y vdd vss wn=1u wp=2u
xpa x a vdd vdd pfet w={wp}
xpb y b x   vdd pfet w={wp}
xpc y c vdd vdd pfet w={wp/2}
xna y a z   vss nfet w={wn}
xnb y b z   vss nfet w={wn}
xnc z c vss vss nfet w={wn}
.ends oai21
.subckt nor2 a b y vdd vss wn=0.5u wp=2.4u
xpa x a vdd vdd pfet w={wp}
xpb y b x   vdd pfet w={wp}
xna y a vss vss nfet w={wn}
xnb y b vss vss nfet w={wn}
.ends nor2

* Bias, VDD33 domain.  OTA (XO1..XO4, tail XO0 from RT / XT1, about 200 uA,
* not from I0, so no start-up circuit) drives vbp so that V(fb) = V(vref).
* The reference branch is a replica of the HS output branch at 2 / 356: XR
* (2 units of XS), XRE (XE / 178, gate at 0 V like XE when on), XRS (XSP /
* 178, gate at 0 V, n-well on its source like XSP): I(XR) = V(vref) / RREF =
* 100 uA, and XS carries 178 times that at nearly the same drain voltage.
* vbp carries the 17 pF gate of XS: it is the OTA's dominant pole.  XNB / XND:
* 50 uA into the nch33 diode -> nb.
.subckt xc_bias vref vbp nb vdd vss rt=12k
rt  vdd vbt {rt}
* RT: poly
xt1 vbt vbt vss vss nfet33 w=4u l=1u
xo0 ot  vbt vss vss nfet33 w=4u l=1u
xo1 o1  fb  ot  vss nfet33 w=20u l=0.5u
xo2 vbp vref ot vss nfet33 w=20u l=0.5u
xo3 o1  o1  vdd vdd pfet33 w=20u l=0.5u
xo4 vbp o1  vdd vdd pfet33 w=20u l=0.5u
xr  rd  vbp vdd vdd pfet33 w=10u l=1u m=2
xre rx  vss rd  vdd pfet33 w=3.4u l=0.35u
xrs fb  vss rx  rx  pfet33 w=2.25u l=0.35u
rref fb vss 12k
* RREF: poly, same type as the termination resistors (sets the HS amplitude;
* the TX_AMP trim goes here, spec 6)
xnb nb  vbp vdd vdd pfet33 w=10u l=1u
xnd nb  nb  vss vss nfet33 w=5u l=1u
.ends xc_bias

* HS current driver.  en (VDD18) = TX_EN & pok; e33b (VDD33) = !en, drives
* the enable switch XE.  Ready timer: CR is precharged to VDD18 while en = 0
* and discharged by XTS (nb, about 5 uA) once en = 1; rdy rises when it
* crosses the inverter threshold (14 / 16 / 17 ns at ss / tt / ff: the line
* must show the J of the lead well before SYNC, 20.8 ns after TX_EN, and stay
* quiet for t_en / 2 = 10 ns).  Steering (VDD18 core logic):
*   XSP on when rdy & (p | !n), XSN on when rdy & (n | !p), XSD on when !rdy
* so P = N opens both (current splits, as the model), and on each data edge
* the switch that turns on does so one inverter earlier than the other turns
* off (make before break: cs never loses its current path); the final
* pre-drivers (sinv: fast pull-down, pull-up starved at msp x 50 uA from the
* reference) set the line edge.
* Sizing against PVT: the switch that turns off needs its gate above
* cs - |Vth|, and the gates only swing to VDD18.  At ss / 125 C / 1.62 V cs
* sat at 1.92 V with 8-unit switches, so the starved pull-up ran out of
* headroom, the old switch stayed half on and alternating bits reached only
* 358 mV (first SYNC bit -11.6 %).  12-unit switches (lower Vov, cs 1.68 V),
* a 24 um series pfet in sinv (more headroom near VDD18) and msp = 18 settle
* every bit within 1.3 % at all three corners; more msp would push the ff
* edge below 500 ps (USB).  Wider pre-driver pull-downs or TGs do not help:
* the edge tail is the turn-off ramp, and more TG capacitance slows it.
* XKP / XKN / XKD (8 um) must park the larger switch gates before XKC pulls
* cs to VDD33, or a switch conducts from VDD33 into the line after TX_EN
* falls (11 mV left 5 ns later at ss with 4 um).
* Parking: the 0 .. 1.8 V gate drive keeps XSP / XSN off only while the line
* is at HS levels (<= 0.8 V).  With FS / LS on the line (DP or DM at 3.3 V) a
* gate at 1.8 V would turn them on, and their n-wells on cs would conduct.  So
* while TX is disabled (e33 = 0) XKP / XKN / XKD pull the three gates and XKC
* pulls cs to VDD33, and the thick-oxide transmission gates XTP / XTN / XTD
* cut the 1.8 V pre-drivers off those nodes: every junction on DP / DM is
* reverse biased.  e33 / e33b are TX_EN in the VDD33 domain.
.subckt hs_tx p n en e33 e33b dp dm vbp nb vdd vddl vss msp=18
* output branch
xs  sd vbp   vdd vdd pfet33 w=10u l=1u m=356
xe  cs e33b sd  vdd pfet33 w=50u l=0.35u m=12
xsp dp gp csp cs pfet33 w=50u l=0.35u m=12
rsp csp cs 10
xsn dm gn csn cs pfet33 w=50u l=0.35u m=12
rsn csn cs 10
xsd dq gd csd cs pfet33 w=50u l=0.35u m=12
rsd csd cs 10
rdq dq vss 22.5
* RSP / RSN / RSD: source degeneration, poly.  They widen the gate-voltage
* window over which the current moves between switches by I x R = 0.18 V,
* independent of the corner, which narrows the PVT spread of the line edge;
* more (25 Ohm) takes too much headroom from XS at VDD33 = 3.0 V.
* RDQ: dump load, poly (same as the line: 45 || 45 Ohm)
* VDD18 bias for the pre-driver pull-ups: 50 uA from nb into the pfet diode XB1
xb0 pbs nb  vss  vss  nfet33 w=5u l=1u
xb1 pbs pbs vddl vddl pfet w=5u l=0.36u
cpb pbs vddl 1p
* CPB: MOS capacitor (holds pbs while the pre-drivers switch)
* input buffers
xi0 p  pb  vddl vss inv
xi1 pb pq  vddl vss inv
xi2 n  nbr vddl vss inv
xi3 nbr nq vddl vss inv
* ready timer
xt0 cr  en  vddl vddl pfet w=1u
xt1 cr  en  ct   vss nfet w=1u
xts ct  nb  vss  vss nfet33 w=1u l=2u
cr  cr  vss 0.085p
* CR: MIM
xt2 cr  rb  vddl vss inv
xt3 rb  en  rn vddl vss nand2
xt4 rn  rdy vddl vss inv
* steering logic and pre-drivers (the last stage, sinv, sets the line edge)
xgp pq  nbr rdy yp vddl vss oai21
xgn nq  pb  rdy yn vddl vss oai21
xbp0 yp ypb vddl vss inv wn=1u wp=2.5u
xbp1 ypb gpi pbs vddl vss sinv mp={msp}
xbn0 yn ynb vddl vss inv wn=1u wp=2.5u
xbn1 ynb gni pbs vddl vss sinv mp={msp}
xbd0 rdy rdb vddl vss inv wn=1u wp=2.5u
xbd1 rdb gdi pbs vddl vss sinv mp={msp}
* parking (see above)
xtpn gpi e33  gp vss nfet33 w=12u
xtpp gpi e33b gp vdd pfet33 w=12u
xtnn gni e33  gn vss nfet33 w=12u
xtnp gni e33b gn vdd pfet33 w=12u
xtdn gdi e33  gd vss nfet33 w=12u
xtdp gdi e33b gd vdd pfet33 w=12u
xkp gp e33 vdd vdd pfet33 w=8u
xkn gn e33 vdd vdd pfet33 w=8u
xkd gd e33 vdd vdd pfet33 w=8u
xkc cs e33 vdd vdd pfet33 w=10u
.ends hs_tx

* FS / LS driver, one wire, VDD33.  u = 1: pull-up on, d = 1: pull-down on
* (u, ub, d, db, fs, fsb all VDD33 levels; fs = 1: FS slew).  XMP / XMN +
* RS: about 34 Ohm.  Gate gp: XPO pulls it to VDD33 at once when u = 0; when
* u = 1, XPLS (LS, 5/2 against the 5/1 nb reference) and XPFS / XPFI (FS,
* mfn x 50 uA more) pull it down
* through XPN, and CMP from the drain makes the output rise at I / CMP.  Gate
* gn mirrors that with PMOS sources from vbp.  CGB balances the gate
* capacitance of XMN against XMP, so DP and DM start moving at the same time
* (crossover in the middle).
.subckt fs_drv o pad u d ub db fs fsb vbp nb vdd vss cm=1p cgb=0.5p mfn=7 mfp=7
xmp o  gp vdd vdd pfet33 w=40u l=0.35u m=14
xmn o  gn vss vss nfet33 w=40u l=0.35u m=6
rs  o  pad 26
* RS: poly, wide (USB driver impedance 28 .. 44 Ohm incl. RS)
* pull-up gate
xpo  gp u  vdd vdd pfet33 w=20u
xpn  gp u  pa  vss nfet33 w=10u
xpls pa nb vss vss nfet33 w=5u l=2u
xpfs pa fs pb  vss nfet33 w=10u
xpfi pb nb vss vss nfet33 w=5u l=1u m={mfn}
cmp  o  gp {cm}
* pull-down gate
xno  gn db vss vss nfet33 w=10u
xnp  gn db na  vdd pfet33 w=20u
xnls na vbp vdd vdd pfet33 w=10u l=2u
xnfs na fsb nc vdd pfet33 w=20u
xnfi nc vbp vdd vdd pfet33 w=10u l=1u m={mfp}
cmn  o  gn {cm}
cgb  gn vss {cgb}
* CMP, CMN, CGB: MIM
.ends fs_drv

* Single-ended receiver: CMOS Schmitt trigger on VDD33, y = a.  Switches high
* above about 1.57 V and low below 1.26 V (tt; 1.53 / 1.21 .. 1.64 / 1.31 V
* over the corners): centre near the model's 1.4 V, inside USB 0.8 .. 2.0 V.
.subckt se_rx a y vdd vss
xp1 x1 a  vdd vdd pfet33 w=2.5u
xp2 yb a  x1  vdd pfet33 w=2.5u
xp3 x1 yb vss vdd pfet33 w=0.8u
xn1 x2 a  vss vss nfet33 w=2.5u
xn2 yb a  x2  vss nfet33 w=2.5u
xn3 x2 yb vdd vss nfet33 w=0.8u
xo  yb y  vdd vss inv33
.ends se_rx

* Differential receiver: rail-to-rail input, y = 1 when a > b.  PMOS pair
* XP1 / XP2 (tail 50 uA from vbp) into the NMOS diodes XN5 / XN6, NMOS pair
* XN1 / XN2 (tail 50 uA from nb) into the PMOS diodes XP5 / XP6.  The two
* currents that grow when a > b, I(XN1) and I(XP2), are summed in the diode
* XP5 (XN7 copies I(XP2) into it) and mirrored up into o by XP7; the two that
* grow when a < b, I(XP1) and I(XN2), are summed in XN5 (XP8 copies I(XN2))
* and mirrored down by XN8.  So o swings rail to rail at any common mode: only
* the PMOS pair works at the chirp common mode (0.4 V), only the NMOS pair
* near VDD33.  Hysteresis: XHP / XHN add +-I_h to o in the direction of the
* present output.
.subckt diff_rx a b y vbp nb vdd vss
xpt sp  vbp vdd vdd pfet33 w=10u l=1u
xp1 d1p a   sp  sp  pfet33 w=20u l=0.5u
xp2 d2p b   sp  sp  pfet33 w=20u l=0.5u
xn5 d1p d1p vss vss nfet33 w=8u l=0.5u
xn6 d2p d2p vss vss nfet33 w=8u l=0.5u
xnt sn  nb  vss vss nfet33 w=5u l=1u
xn1 d1n a   sn  vss nfet33 w=10u l=0.5u
xn2 d2n b   sn  vss nfet33 w=10u l=0.5u
xp5 d1n d1n vdd vdd pfet33 w=16u l=0.5u
xp6 d2n d2n vdd vdd pfet33 w=16u l=0.5u
xn7 d1n d2p vss vss nfet33 w=8u l=0.5u
xp8 d1p d2n vdd vdd pfet33 w=16u l=0.5u
xp7 o   d1n vdd vdd pfet33 w=16u l=0.5u
xn8 o   d1p vss vss nfet33 w=8u l=0.5u
* output and hysteresis
xo0 o  ob vdd vss inv33
xo1 ob y  vdd vss inv33
xhps hp vbp vdd vdd pfet33 w=10u l=4u
xhpw o  ob  hp  vdd pfet33 w=1u
xhns hn nb  vss vss nfet33 w=5u l=4u
xhnw o  ob  hn  vss nfet33 w=1u
.ends diff_rx

* UVLO, VDD33: tap = VDD33 * RU2 / (RU1 + RU2 [+ RUH]) against vref (nch33
* pair, 10 uA tail).  pok = 0 shorts RUH: on above 1.2 V * 490 / 200 =
* 2.94 V, off below 1.2 V * 500 / 210 = 2.86 V.
.subckt uvlo vref pok vbp nb vdd vss
ru1 vdd tap 290k
ru2 tap uh  200k
ruh uh  vss 10k
* RU1, RU2, RUH: high-ohmic poly
xuh uh  pokb vss vss nfet33 w=2u
xut ut  nb  vss vss nfet33 w=1u l=1u
xu1 u1  tap ut  vss nfet33 w=4u l=1u
xu2 uo  vref ut vss nfet33 w=4u l=1u
xu3 u1  u1  vdd vdd pfet33 w=4u l=1u
xu4 uo  u1  vdd vdd pfet33 w=4u l=1u
xi0 uo  pokb vdd vss inv33
xi1 pokb pok vdd vss inv33
.ends uvlo

*------------------------------------------------------------- top level
.subckt afe_transceiver_tr tx_in_p tx_in_n tx_en tx_i_5u tx_vref tx_cap_p tx_cap_n
+ fs_oe_a fs_dat_a fs_se0_a fs_ls_a fs_rx_en_a rxrcv_a rxdp_a rxdm_a
+ dp_pullup_en_a hs_term_en_a pd_en_a0 pd_en_a1 dp dm vdd33 vdd18 gnd ckv=1p msp=18 rt=12k
ri5 tx_i_5u gnd 1g
rcp tx_cap_p dp 1t
rcn tx_cap_n dm 1t
xbias tx_vref vbp nb vdd33 gnd xc_bias rt={rt}
xuv tx_vref pok33 vbp nb vdd33 gnd uvlo
xpk0 pok33 pokb18 vdd18 gnd ls_dn
xpk1 pokb18 pok vdd18 gnd inv

* ---- HS TX
xe0 tx_en pok ten_n vdd18 gnd nand2
xe1 ten_n ten vdd18 gnd inv
xe2 ten ten33 ten33b vdd18 vdd33 gnd ls_up
xe3 ten33 eb1 vdd33 gnd inv33 wn=2u wp=5u
xe4 eb1 eb2 vdd33 gnd inv33 wn=8u wp=20u
xe5 eb2 en33b vdd33 gnd inv33 wn=8u wp=20u
ck  eb2 vbp {ckv}
* CK: MIM, cancels the charge XS's gate loses when its drain leaves triode
xhs tx_in_p tx_in_n ten eb2 en33b dp dm vbp nb vdd33 vdd18 gnd hs_tx msp={msp}

* ---- FS / LS driver control (VDD18): x = DAT ^ LS; DP high = !SE0 & x
xf0 fs_oe_a pok oen vdd18 gnd nand2
xf1 oen oe vdd18 gnd inv
xf2 fs_dat_a fs_ls_a x0 vdd18 gnd nand2
xf3 fs_dat_a x0 x1 vdd18 gnd nand2
xf4 fs_ls_a  x0 x2 vdd18 gnd nand2
xf5 x1 x2 xx vdd18 gnd nand2
xf6 xx xxb vdd18 gnd inv
xf7 fs_se0_a xxb tp vdd18 gnd nor2
xf8 fs_se0_a xx  tm vdd18 gnd nor2
xf9 tp tpb vdd18 gnd inv
xf10 tm tmb vdd18 gnd inv
xf11 oe tp  upn vdd18 gnd nand2
xf12 oe tpb dpn vdd18 gnd nand2
xf13 oe tm  umn vdd18 gnd nand2
xf14 oe tmb dmn vdd18 gnd nand2
* level shifters take the inverted signals: y = !u etc., yb = u
xl0 upn upb33 up33 vdd18 vdd33 gnd ls_up
xl1 dpn dpb33 dp33 vdd18 vdd33 gnd ls_up
xl2 umn umb33 um33 vdd18 vdd33 gnd ls_up
xl3 dmn dmb33 dm33 vdd18 vdd33 gnd ls_up
xl4 fs_ls_a ls33 fs33 vdd18 vdd33 gnd ls_up
xfp odp dp up33 dp33 upb33 dpb33 fs33 ls33 vbp nb vdd33 gnd fs_drv
xfm odm dm um33 dm33 umb33 dmb33 fs33 ls33 vbp nb vdd33 gnd fs_drv

* ---- receivers
xrp dp sp33 vdd33 gnd se_rx
xrm dm sm33 vdd33 gnd se_rx
xrd dp dm sd33 vbp nb vdd33 gnd diff_rx
xd0 sp33 spb vdd18 gnd ls_dn
xd1 sm33 smb vdd18 gnd ls_dn
xd2 sd33 sdb vdd18 gnd ls_dn
xr0 fs_rx_en_a pok rxonb vdd18 gnd nand2
xr1 rxonb rxon vdd18 gnd inv
* RXDP_A = sp & on, RXDM_A = sm & on, RXRCV_A = sd | !on
xr2 spb rxonb rpn vdd18 gnd nor2
xr3 smb rxonb rmn vdd18 gnd nor2
xr4 sdb rxon rdn vdd18 gnd nand2
xr5 rpn rpb vdd18 gnd inv
xr6 rmn rmb vdd18 gnd inv
xr7 rdn rdb vdd18 gnd inv
xr8 rpb rxdp_a vdd18 gnd inv wn=1u wp=2.5u
xr9 rmb rxdm_a vdd18 gnd inv wn=1u wp=2.5u
xr10 rdb rxrcv_a vdd18 gnd inv wn=1u wp=2.5u

* ---- terminations and pulls
xt0 dp_pullup_en_a pu33 pu33b vdd18 vdd33 gnd ls_up
xt1 pu33b pug1 vdd33 gnd inv33 wn=2u wp=5u
xt2 pug1 pug vdd33 gnd inv33 wn=2u wp=5u
xpu pux pug vdd33 vdd33 pfet33 w=60u
rpu pux dp 1.405k
* RPU: poly
xt3 hs_term_en_a hs33 hs33b vdd18 vdd33 gnd ls_up
xt4 hs33 hsg1 vdd33 gnd inv33 wn=2u wp=5u
xt5 hsg1 hsg vdd33 gnd inv33 wn=8u wp=20u
xhp hpx hsg gnd gnd nfet33 w=40u m=13
xhm hmx hsg gnd gnd nfet33 w=40u m=13
rhp dp hpx 41.6
rhm dm hmx 41.6
* RHP, RHM: poly (HS_TERM trim, spec 6)
xt6 pd_en_a0 pd0g pd0b vdd18 vdd33 gnd ls_up
xt7 pd_en_a1 pd1g pd1b vdd18 vdd33 gnd ls_up
xp0 p0x pd0g gnd gnd nfet33 w=2u
xp1 p1x pd1g gnd gnd nfet33 w=2u
rp0 dp p0x 14k
rp1 dm p1x 14k
* RP0, RP1: high-ohmic poly
.ends afe_transceiver_tr
