#!/usr/bin/env python3
"""draw_receiver.py - SVG schematic sheets of afe_receiver_tr.sp (AFE/spice/afe_receiver_tr.sp)

    python3 AFE/spice/doc/draw_receiver.py      -> AFE/spice/doc/rx_*.svg

Same symbols and conventions as draw_cdr.py (instance names and sizes from
the netlist, W/L in um).  Thick-oxide 3.3 V devices (pch33 / nch33) carry a
"33" after the size; everything else is a 1.8 V core device.  Accent colour:
the signal path of the sheet.
"""
import os
from draw_cdr import Sheet, STYLE, HERE


def gate(s, x, y, name, sub=None, w=50, h=36, acc=False):
    """logic gate as a small box, inputs on the left, output (x + w, y + h / 2)"""
    s.box(x, y, w, h, name, sub, acc=acc)
    return (x + w, y + h / 2)


# =========================================================== top level
def sheet_top():
    s = Sheet(1000, 540, "Top level: DP and DM feed the HS receiver pair, two squelch preamps and two disconnect preamps "
                         "on RX_VDD; their comparators, the squelch filter, the disconnect timer, UVLO and the output "
                         "gating run on RX_VDDO; one bias current I0 = RX_VREF / RB sets every threshold")
    s.text(140, 16, "RX_VDD (3.3 V): input stages, pch33", "middle", "lb")
    s.text(640, 16, "RX_VDDO (1.8 V): comparators, timers, logic, outputs", "middle", "lb")
    s.line((300, 24), (300, 500), dash=True)
    s.pin(-20, 70, "RX_IN_P", "tl", acc=True)
    s.pin(-20, 110, "RX_IN_N", "tl", acc=True)
    s.line((-16, 70), (40, 70), acc=True); s.line((-16, 110), (30, 110), acc=True)
    s.line((40, 70), (40, 330), acc=True); s.line((30, 110), (30, 345), acc=True)
    # HS
    s.box(90, 50, 170, 80, "HS pair XA1/XA2", "200 µA, 3 kΩ loads", acc=True)
    s.line((40, 75), (90, 75), acc=True); s.line((30, 110), (90, 110), acc=True)
    s.dot(40, 75); s.dot(30, 110)
    s.arrow(260, 90, 340, 90, "xa / ya", acc=True)
    s.box(340, 60, 120, 60, "rx_cmp XHS", "hyst. 18 mV", acc=True)
    s.arrow(460, 90, 520, 90, "hsc", acc=True)
    s.box(520, 60, 130, 60, "XH0..XH5", "gate with on", acc=True)
    s.line((650, 75), (900, 75), acc=True); s.pin(904, 75, "RX_OUT_P", "r", acc=True)
    s.line((650, 105), (900, 105)); s.pin(904, 105, "RX_OUT_N", "r")
    # squelch
    s.box(90, 170, 170, 80, "rx_dda XSP, XSN", "|vd| > I0·RSQ", acc=True)
    s.line((40, 195), (90, 195), acc=True); s.line((30, 225), (90, 225), acc=True)
    s.dot(40, 195); s.dot(30, 225)
    s.arrow(260, 210, 340, 210, "x / y (×2)", acc=True)
    s.box(340, 180, 120, 60, "rx_cmp ×2", "XCSP, XCSN", acc=True)
    s.arrow(460, 210, 520, 210, "act", acc=True)
    s.box(520, 165, 230, 90, "squelch filter", "3 rx_tmr + SR latch", acc=True)
    s.text(635, 245, "bridge 3 · on 6 · off 10 ns", "middle", "sz")
    s.arrow(750, 210, 800, 210, "act_f", acc=True)
    s.box(800, 190, 70, 40, "XS5..7", "& on")
    s.line((870, 210), (900, 210), acc=True); s.pin(904, 210, "SQUELCH_A", "r", acc=True)
    # disconnect
    s.box(90, 290, 170, 80, "rx_dda XDP, XDN", "|vd| > I0·RDISC")
    s.line((40, 330), (90, 330)); s.line((30, 345), (90, 345))
    s.dot(40, 330)
    s.arrow(260, 330, 340, 330, "x / y (×2)")
    s.box(340, 300, 120, 60, "rx_cmp ×2", "XCDP, XCDN")
    s.arrow(460, 330, 520, 330, "dsc")
    s.box(520, 305, 140, 50, "rx_tmr XTD", "4 ns, fall at once")
    s.arrow(660, 330, 800, 330, "dsf")
    s.box(800, 310, 70, 40, "XD2, XD3", "& on")
    s.line((870, 330), (900, 330)); s.pin(904, 330, "DISC_A", "r")
    # references
    s.box(90, 420, 170, 60, "references", "I0 into RR0..RR4")
    s.text(175, 498, "rsl/rsh, rdl/rdh → rx_dda", "middle", "sz")
    # bias / enable / UVLO
    s.pin(320, 490, "RX_VREF", "b"); s.line((320, 486), (320, 450), (340, 450))
    s.box(340, 420, 130, 60, "rx_bias", "I0 = VREF / RB")
    s.text(405, 498, "vbp18, vbp33", "middle", "sz")
    s.pin(550, 510, "RX_EN", "b"); s.line((550, 506), (550, 480))
    s.box(490, 420, 120, 60, "enable", "XE0/1, XL0..3")
    s.box(630, 420, 120, 60, "UVLO XCU", "RX_VDD > 2.95 V")
    s.box(770, 420, 100, 60, "ready", "XTRDY 130 ns")
    s.line((820, 420), (820, 395)); s.text(820, 388, "on = en · pok · rdy", "middle", "ar")
    for yb in (230, 350):
        s.line((835, yb), (835, yb + 14)); s.text(835, yb + 26, "on", "middle", "sz")
    return s


# =========================================================== HS receiver
def sheet_hs():
    s = Sheet(1000, 400, "HS receiver: a pch33 differential pair with a 200 µA tail and 3 kΩ poly loads (gain about 2.5, "
                         "outputs below 0.6 V) drives the hysteresis comparator XHS; its output is gated with on into "
                         "RX_OUT_P and RX_OUT_N")
    s.vdd(315, 40, "RX_VDD")
    s.mos(315, 80, "p", "XA0", "10×16/2 33")
    s.line((330, 40), (330, 50))
    s.pin(245, 80, "vbp33", "l"); s.line((249, 80), (285, 80))
    s.line((330, 110), (330, 130)); s.dot(330, 130); s.text(338, 126, "sa", "start", "sz")
    s.line((215, 130), (445, 130))
    s.mos(200, 170, "p", "XA1", "24/0.35 33")
    s.mos(460, 170, "p", "XA2", "24/0.35 33", mirror=True)
    s.line((215, 130), (215, 140)); s.line((445, 130), (445, 140))
    s.text(330, 112, "n-wells to sa", "middle", "sz")
    s.pin(110, 170, "RX_IN_P", "l", acc=True); s.line((114, 170), (170, 170), acc=True)
    s.pin(550, 170, "RX_IN_N", "r", acc=True); s.line((546, 170), (490, 170), acc=True)
    s.line((215, 200), (215, 225)); s.line((445, 200), (445, 225))
    s.dot(215, 225); s.dot(445, 225)
    s.res(215, 225, 300, "RA1", "3 kΩ", lab="l"); s.gnd(215, 300)
    s.res(445, 225, 300, "RA2", "3 kΩ"); s.gnd(445, 300)
    s.line((215, 225), (150, 225), (150, 340), (520, 340), (520, 275), (540, 275), acc=True)
    s.text(146, 238, "xa", "end", "dev")
    s.line((445, 225), (510, 225), (510, 250), (540, 250), acc=True)
    s.text(478, 219, "ya", "middle", "dev")
    s.text(330, 362, "DP > DM: XA1 carries less, xa < ya", "middle", "ar")
    s.box(540, 230, 150, 60, "rx_cmp XHS", "mt 5, wd 2, wx 2.55", acc=True)
    s.text(536, 245, "g2", "end", "sz"); s.text(536, 270, "g1", "end", "sz")
    s.text(615, 308, "out = 1 when g2 > g1", "middle", "sz")
    y = 260
    s.line((690, y), (705, y), acc=True); s.text(697, y - 8, "hsc", "middle", "sz")
    o = s.inv(705, y, "XH0", None, 22)
    s.dot(o[0] + 6, y); s.line(o, (o[0] + 14, y), acc=True)
    s.text(o[0] + 2, y + 30, "hsb", "end", "sz")
    x1 = o[0] + 14
    o2 = s.inv(x1, y, "XH1", None, 22); s.line(o2, (o2[0] + 8, y), acc=True)
    s.text(o2[0] + 12, y + 4, "hs", "start", "sz")
    # NAND / NOR
    gx = o2[0] + 8
    s.line((gx, y), (gx, 200), (gx + 10, 200), acc=True)
    a = gate(s, gx + 10, 182, "XH2", "NAND", acc=True)
    s.pin(gx + 2, 225, "on", "l"); s.line((gx + 6, 225), (gx + 10, 225), (gx + 10, 210))
    s.line((o[0] + 6, y), (o[0] + 6, 330), (gx + 10, 330))
    b = gate(s, gx + 10, 300, "XH3", "NOR")
    s.pin(gx + 2, 360, "onb", "l"); s.line((gx + 6, 360), (gx + 10, 360), (gx + 10, 330))
    o3 = s.inv(a[0] + 10, a[1], "XH4", "2/5", 22); s.line(a, (a[0] + 10, a[1]), acc=True)
    s.line(o3, (o3[0] + 14, a[1]), acc=True); s.pin(o3[0] + 18, a[1], "RX_OUT_P", "t", acc=True)
    o4 = s.inv(b[0] + 10, b[1], "XH5", "2/5", 22); s.line(b, (b[0] + 10, b[1]))
    s.line(o4, (o4[0] + 14, b[1])); s.pin(o4[0] + 18, b[1], "RX_OUT_N", "b")
    s.text(880, 140, "RX_OUT_P = hs · on", "middle", "ar")
    s.text(880, 385, "RX_OUT_N = !(hs · on)", "middle", "ar")

    return s


# =========================================================== comparator
def sheet_cmp():
    s = Sheet(1000, 420, "Comparator rx_cmp (RX_VDDO): PMOS input pair, diode loads XC3/XC4 with cross-coupled XC5/XC6 "
                         "(wider than the diodes gives hysteresis), output stage XC7-XC10 mirrors the two branch "
                         "currents into out; enb clears out, d1 and d2 while the tail is off")
    s.vdd(315, 30, "RX_VDDO")
    s.mos(300, 70, "p", "XC0", "mt×8/1")
    s.line((315, 30), (315, 40))
    s.pin(230, 70, "vbp18", "l"); s.line((234, 70), (270, 70))
    s.line((315, 100), (315, 115)); s.dot(315, 115); s.text(323, 112, "s", "start", "sz")
    s.line((245, 115), (385, 115))
    s.mos(230, 155, "p", "XC1", "wi/0.25")
    s.mos(400, 155, "p", "XC2", "wi/0.25", mirror=True)
    s.line((245, 115), (245, 125)); s.line((385, 115), (385, 125))
    s.pin(150, 155, "g1", "l", acc=True); s.line((154, 155), (200, 155), acc=True)
    s.pin(480, 155, "g2", "r", acc=True); s.line((476, 155), (430, 155), acc=True)
    s.line((245, 185), (245, 215)); s.line((385, 185), (385, 215))
    s.dot(245, 215); s.dot(385, 215)
    s.text(236, 211, "d1", "end", "dev"); s.text(394, 211, "d2", "start", "dev")
    # diode loads (outer) and cross-coupled (inner)
    s.line((245, 215), (115, 215), (115, 235)); s.line((385, 215), (515, 215), (515, 235))
    s.mos(100, 265, "n", "XC3", "wd/0.25")
    s.line((70, 265), (60, 265), (60, 225), (115, 225)); s.dot(115, 225)
    s.mos(530, 265, "n", "XC4", "wd/0.25", mirror=True)
    s.line((560, 265), (570, 265), (570, 225), (515, 225)); s.dot(515, 225)
    s.mos(230, 265, "n", "XC5", "wx/0.25")
    s.mos(400, 265, "n", "XC6", "wx/0.25", mirror=True)
    s.line((245, 215), (245, 235)); s.line((385, 215), (385, 235))
    s.line((200, 265), (185, 265)); s.text(181, 269, "d2", "end", "dev")
    s.line((430, 265), (445, 265)); s.text(449, 269, "d1", "start", "dev")
    s.text(315, 330, "cross-coupled XC5/XC6: wx > wd → hysteresis", "middle", "ar")
    for x in (115, 245, 385, 515):
        s.line((x, 295), (x, 310)); s.gnd(x, 310)
    # output stage
    X = 640
    s.vdd(X + 15, 30, "RX_VDDO"); s.vdd(X + 185, 30, "RX_VDDO")
    s.mos(X + 30, 75, "p", "XC9", "2.5·wo", mirror=True)
    s.mos(X + 170, 75, "p", "XC10", "2.5·wo")
    s.line((X + 15, 30), (X + 15, 45)); s.line((X + 185, 30), (X + 185, 45))
    s.line((X + 60, 75), (X + 140, 75)); s.dot(X + 100, 75)
    s.line((X + 100, 75), (X + 100, 120), (X + 15, 120)); s.dot(X + 15, 120)
    s.text(X + 8, 130, "o7", "end", "sz")
    s.line((X + 15, 105), (X + 15, 205)); s.line((X + 185, 105), (X + 185, 205))
    s.mos(X, 235, "n", "XC7", "wo/0.25")
    s.mos(X + 200, 235, "n", "XC8", "wo/0.25", mirror=True)
    s.line((X - 30, 235), (X - 50, 235)); s.text(X - 54, 239, "d1", "end", "dev")
    s.line((X + 230, 235), (X + 250, 235)); s.text(X + 254, 239, "d2", "start", "dev")
    s.line((X + 15, 265), (X + 15, 280)); s.gnd(X + 15, 280)
    s.line((X + 185, 265), (X + 185, 280)); s.gnd(X + 185, 280)
    s.dot(X + 185, 150)
    s.line((X + 185, 150), (X + 300, 150), acc=True); s.pin(X + 304, 150, "out", "r", acc=True)
    s.text(X + 100, 180, "out: I(d1)·k up vs I(d2)·k down", "middle", "ar")
    s.mos(X + 270, 340, "n", "XC11", "0.5/0.18")
    s.line((X + 285, 310), (X + 285, 150)); s.dot(X + 285, 150)
    s.line((X + 240, 340), (X + 225, 340)); s.text(X + 221, 344, "enb", "end", "sz")
    s.line((X + 285, 370), (X + 285, 380)); s.gnd(X + 285, 380)
    s.text(X + 100, 330, "XC12, XC13 (0.3/0.18): d1, d2 → 0 on enb", "middle", "sz")
    s.text(X + 100, 400, "instances: XHS (HS), XCSP/XCSN (squelch), XCDP/XCDN (disc.), XCU (UVLO)", "middle", "sz")
    return s


# =========================================================== preamp + references
def sheet_dda():
    s = Sheet(1000, 420, "Squelch and disconnect preamp rx_dda (RX_VDD): pair A compares RX_IN_P with RX_IN_N, pair B "
                         "compares the two references; their drain currents add in x and y, so y rises above x when "
                         "DP - DM exceeds the reference difference; the references come from I0 in a poly string")
    s.vdd(150, 30, "RX_VDD"); s.vdd(470, 30, "RX_VDD")
    for cx, nm, a, b, ga, gb in ((150, "XTA", "XA1", "XA2", "in1", "in2"), (470, "XTB", "XB1", "XB2", "rl", "rh")):
        s.mos(cx - 15, 70, "p", nm, "mt×16/2 33")
        s.line((cx, 30), (cx, 40))
        s.pin(cx - 85, 70, "vbp33", "l"); s.line((cx - 81, 70), (cx - 45, 70))
        s.line((cx, 100), (cx, 112)); s.dot(cx, 112)
        s.line((cx - 60, 112), (cx + 60, 112))
        s.mos(cx - 75, 150, "p", a, "w/l 33")
        s.mos(cx + 75, 150, "p", b, "w/l 33", mirror=True)
        s.line((cx - 60, 112), (cx - 60, 120)); s.line((cx + 60, 112), (cx + 60, 120))
        acc = ga == "in1"
        s.pin(cx - 115, 150, ga, "l", acc=acc); s.line((cx - 111, 150), (cx - 105, 150), acc=acc)
        s.pin(cx + 115, 150, gb, "r", acc=acc); s.line((cx + 111, 150), (cx + 105, 150), acc=acc)
    # x = XA1 + XB1, y = XA2 + XB2
    s.line((90, 180), (90, 230), (410, 230), (410, 180), acc=True)
    s.line((210, 180), (210, 260), (530, 260), (530, 180), acc=True)
    s.dot(90, 230); s.dot(210, 260)
    s.res(90, 230, 320, "R1", "rld", lab="l"); s.gnd(90, 320)
    s.line((210, 260), (210, 270)); s.res(210, 270, 340, "R2", "rld"); s.gnd(210, 340)
    s.text(300, 224, "x", "middle", "dev"); s.text(370, 254, "y", "middle", "dev")
    s.line((410, 230), (600, 230), acc=True); s.pin(604, 230, "x → g1", "r", acc=True)
    s.line((530, 260), (600, 260), acc=True); s.pin(604, 260, "y → g2", "r", acc=True)
    s.text(300, 370, "y > x when in1 − in2 > rh − rl", "middle", "ar")
    s.text(300, 390, "XSP: in1 = DP · XSN: in1 = DM (same for XDP / XDN)", "middle", "sz")
    # table of instances
    s.text(300, 410, "squelch: mt 5, 16/0.5, 3 kΩ (Vov 0.22 V) · disconnect: mt 2, 1/0.5, 7.5 kΩ (Vov 0.56 V)", "middle", "sz")
    # reference string
    X = 790
    s.text(X + 20, 16, "reference string", "middle", "lb")
    s.vdd(X, 30, "RX_VDD")
    s.mos(X - 15, 60, "p", "XR0", "16/2 33")
    s.line((X, 30), (X, 30))
    s.line((X - 45, 60), (X - 60, 60)); s.text(X - 64, 64, "vbp33", "end", "sz")
    s.line((X, 90), (X, 100))
    s.res(X, 100, 150, "RR0", "21.25 kΩ", lab="l")
    nodes = [("rdh", "0.6725 V", "RR1", "21.25 kΩ"), ("rsh", "0.2475 V", "RR2", "5.25 kΩ"),
             ("rsl", "0.1425 V", "RR3", "1.5 kΩ"), ("rdl", "0.1125 V", "RR4", "5.625 kΩ")]
    y = 150
    for nm, v, rn, rv in nodes:
        s.dot(X, y)
        s.line((X, y), (X + 40, y)); s.cap(X + 40, y, y + 40, "", "", lab="r")
        s.gnd(X + 40, y + 40)
        s.text(X + 62, y + 4, f"{nm} {v}", "start", "dev")
        s.res(X, y, y + 60, rn, rv, lab="l")
        y += 60
    s.gnd(X, y)
    s.text(X + 40, y + 28, "CR0..CR3 0.5 pF", "middle", "sz")
    s.text(X - 10, y + 48, "RSQ = RR2 → 105 mV · RDISC = RR1+RR2+RR3 → 560 mV", "middle", "sz")
    return s


# =========================================================== filter logic
def sheet_logic():
    s = Sheet(1000, 500, "Squelch filter and disconnect timer (RX_VDDO): the bridge timer keeps env high across dips "
                         "shorter than 3 ns, the on and off timers set and reset the act_f latch; the disconnect "
                         "timer needs 4 ns of dsc and falls at once; all outputs are gated with on")
    # rx_tmr transistor level, bottom left
    X, Y = 60, 250
    s.text(X + 120, Y - 12, "rx_tmr (ramp timer)", "middle", "lb")
    s.vdd(X + 115, Y + 5, "RX_VDDO")
    s.mos(X + 100, Y + 40, "p", "XT0", "wi/1")
    s.line((X + 115, Y + 5), (X + 115, Y + 10))
    s.line((X + 70, Y + 40), (X + 55, Y + 40)); s.text(X + 51, Y + 44, "vbp18", "end", "sz")
    s.mos(X + 100, Y + 100, "p", "XT1", "2/0.18")
    s.line((X + 115, Y + 70), (X + 115, Y + 70))
    s.line((X + 70, Y + 100), (X + 55, Y + 100)); s.text(X + 51, Y + 104, "inb", "end", "sz")
    s.dot(X + 115, Y + 140); s.line((X + 115, Y + 130), (X + 115, Y + 150))
    s.mos(X + 100, Y + 180, "n", "XT2", "2/0.18")
    s.line((X + 70, Y + 180), (X + 55, Y + 180)); s.text(X + 51, Y + 184, "inb", "end", "sz")
    s.line((X + 115, Y + 210), (X + 115, Y + 215)); s.gnd(X + 115, Y + 215)
    s.line((X + 115, Y + 140), (X + 175, Y + 140)); s.dot(X + 175, Y + 140)
    s.cap(X + 175, Y + 160, Y + 210, "CT", "c"); s.line((X + 175, Y + 140), (X + 175, Y + 160)); s.gnd(X + 175, Y + 210)
    s.text(X + 120, Y + 136, "r", "start", "dev")
    s.line((X + 175, Y + 140), (X + 205, Y + 140))
    o = s.inv(X + 205, Y + 140, "XI0", None, 20); o = s.inv(o[0] + 6, Y + 140, "XI1", None, 20)
    s.line(o, (o[0] + 12, Y + 140)); s.pin(o[0] + 16, Y + 140, "out", "r")
    s.text(X + 300, Y + 190, "t = c · VDDO/2 / I", "middle", "ar")
    s.text(X + 300, Y + 208, "XT3: r → 0 on enb", "middle", "sz")
    # squelch chain, top
    y = 70
    s.pin(20, y, "sqp", "l", acc=True); s.pin(20, y + 30, "sqn", "l", acc=True)
    s.line((24, y), (40, y), acc=True); s.line((24, y + 30), (40, y + 30), acc=True)
    a = gate(s, 40, y - 3, "XS0", "NOR 2/1", acc=True)
    s.line(a, (115, a[1]), acc=True); s.dot(115, a[1]); s.text(115, a[1] - 8, "actb", "middle", "sz")
    b = gate(s, 130, y - 3, "XTBR", "3 ns", w=70, acc=True)
    s.line((115, a[1]), (130, a[1]), acc=True)
    s.line(b, (220, b[1]), acc=True); s.dot(220, b[1]); s.text(225, b[1] - 8, "bt", "start", "sz")
    o = s.inv(240, b[1], None, None, 20); s.line((220, b[1]), (240, b[1]), acc=True)
    s.text(250, b[1] + 26, "XS2", "middle", "dev")
    s.line(o, (300, b[1]), acc=True); s.text(282, b[1] - 8, "env", "middle", "sz")
    c = gate(s, 300, y - 3, "XTON", "6 ns", w=70, acc=True)
    s.line(c, (430, c[1]), acc=True); s.text(400, c[1] - 8, "son", "middle", "sz")
    s.line((220, b[1]), (220, 150), (300, 150))
    d = gate(s, 300, 132, "XTOF", "10 ns", w=70)
    s.line(d, (430, d[1])); s.text(400, d[1] - 8, "sof", "middle", "sz")
    s.box(430, 60, 120, 110, "SR latch", "XS3 NOR3, XS4 NOR2", acc=True)
    s.text(440, 82, "S", "start", "sz"); s.text(440, 155, "R", "start", "sz")
    s.text(490, 190, "reset also on !on", "middle", "sz")
    s.line((550, 100), (600, 100), acc=True); s.text(575, 92, "act_f", "middle", "sz")
    e = gate(s, 600, 82, "XS5", "NAND", acc=True)
    s.pin(592, 140, "on", "l"); s.line((596, 140), (600, 140), (600, 112))
    o = s.inv(e[0] + 10, e[1], "XS6", None, 20); s.line(e, (e[0] + 10, e[1]), acc=True)
    o = s.inv(o[0] + 6, e[1], "XS7", None, 20)
    s.line(o, (o[0] + 20, e[1]), acc=True); s.pin(o[0] + 24, e[1], "SQUELCH_A", "r", acc=True)
    # disconnect
    y = 290
    X = 480
    s.pin(X - 10, y, "dsp", "l"); s.pin(X - 10, y + 30, "dsn", "l")
    s.line((X - 6, y), (X + 10, y)); s.line((X - 6, y + 30), (X + 10, y + 30))
    a = gate(s, X + 10, y - 3, "XD0", "NOR")
    o = s.inv(a[0] + 10, a[1], "XD1", None, 20); s.line(a, (a[0] + 10, a[1]))
    s.line(o, (o[0] + 10, a[1])); s.text(o[0] + 5, a[1] - 8, "dsc", "middle", "sz")
    b = gate(s, o[0] + 10, y - 3, "XTD", "4 ns", w=60)
    c = gate(s, b[0] + 20, y - 3, "XD2", "NAND")
    s.line(b, (b[0] + 20, b[1])); s.text(b[0] + 10, b[1] - 8, "dsf", "middle", "sz")
    s.pin(b[0] + 12, y + 50, "on", "l"); s.line((b[0] + 16, y + 50), (b[0] + 20, y + 50), (b[0] + 20, y + 30))
    o = s.inv(c[0] + 10, c[1], "XD3", None, 20); s.line(c, (c[0] + 10, c[1]))
    s.line(o, (o[0] + 20, c[1])); s.pin(o[0] + 24, c[1], "DISC_A", "r")
    s.text(X + 230, y + 90, "DISC_A = dsc held 4 ns · on (falls with dsc)", "middle", "ar")
    return s


# =========================================================== bias, enable, UVLO
def sheet_bias():
    s = Sheet(1000, 470, "Bias, enable and UVLO: an OTA forces RX_VREF across RB, so I0 = VREF / 60 kΩ; vbp18 is the "
                         "1.8 V current-source gate, a 4·I0 mirror chain makes vbp33 on RX_VDD; RX_EN is level-shifted "
                         "to RX_VDD; the UVLO compares RX_VDD / 5.74 with I0 · 25 kΩ")
    X = 40
    s.vdd(X + 100, 30, "RX_VDDO"); s.vdd(X + 240, 30, "RX_VDDO")
    s.mos(X + 115, 75, "p", "XO3", "4/0.5", mirror=True)
    s.mos(X + 225, 75, "p", "XO4", "4/0.5")
    s.line((X + 100, 30), (X + 100, 45)); s.line((X + 240, 30), (X + 240, 45))
    s.line((X + 145, 75), (X + 195, 75)); s.dot(X + 170, 75)
    s.line((X + 170, 75), (X + 170, 115), (X + 100, 115)); s.dot(X + 100, 115)
    s.line((X + 100, 105), (X + 100, 135)); s.line((X + 240, 105), (X + 240, 135))
    s.mos(X + 85, 165, "n", "XO1", "4/0.5")
    s.mos(X + 255, 165, "n", "XO2", "4/0.5", mirror=True)
    s.line((X + 100, 195), (X + 100, 210), (X + 240, 210), (X + 240, 195)); s.dot(X + 170, 210)
    s.mos(X + 155, 245, "n", "XO0", "2/1")
    s.line((X + 170, 210), (X + 170, 215)); s.line((X + 170, 275), (X + 170, 285)); s.gnd(X + 170, 285)
    s.line((X + 125, 245), (X + 110, 245)); s.text(X + 106, 249, "vbt", "end", "sz")
    s.text(X + 20, 300, "vbt: XT0 (en) + RT 40 kΩ + XT1 2/1", "start", "sz")
    s.pin(X + 330, 165, "RX_VREF", "r", acc=True); s.line((X + 326, 165), (X + 285, 165), acc=True)
    s.dot(X + 240, 120); s.line((X + 240, 120), (X + 380, 120), acc=True)
    s.text(X + 300, 112, "vbp18", "middle", "dev")
    s.cap(X + 330, 60, 120, "CC", "0.3 pF"); s.line((X + 330, 60), (X + 330, 40)); s.text(X + 330, 34, "RX_VDDO", "middle", "rail")
    s.dot(X + 330, 120)
    # pass device and RB
    P = X + 420
    s.vdd(P + 15, 30, "RX_VDDO")
    s.mos(P, 90, "p", "XM0", "8/1")
    s.line((P + 15, 30), (P + 15, 60)); s.line((X + 380, 120), (X + 380, 90), (P - 30, 90), acc=True)
    s.line((P + 15, 120), (P + 15, 150)); s.dot(P + 15, 150)
    s.text(P + 22, 146, "fb", "start", "dev")
    s.res(P + 15, 150, 230, "RB", "60 kΩ"); s.gnd(P + 15, 230)
    s.line((P + 15, 150), (P - 20, 150), (P - 20, 320), (X + 30, 320), (X + 30, 165), (X + 55, 165))
    s.text(P - 26, 260, "fb → XO1", "end", "ar")
    s.text(P + 40, 260, "I0 = V(RX_VREF) / RB = 20 µA", "start", "ar")
    # 3.3 V chain
    Q = X + 620
    s.vdd(Q + 15, 30, "RX_VDDO")
    s.mos(Q, 75, "p", "XM1", "4×8/1")
    s.line((Q + 15, 30), (Q + 15, 45)); s.line((Q - 30, 75), (Q - 40, 75)); s.text(Q - 44, 79, "vbp18", "end", "sz")
    s.line((Q + 15, 105), (Q + 15, 130)); s.dot(Q + 15, 130)
    s.text(Q + 22, 128, "n33", "start", "sz")
    s.line((Q + 15, 130), (Q + 15, 145))
    s.mos(Q, 175, "n", "XN33D", "4×4/2 33")
    s.line((Q - 30, 175), (Q - 40, 175), (Q - 40, 130), (Q + 15, 130))
    s.line((Q + 15, 205), (Q + 15, 215)); s.gnd(Q + 15, 215)
    s.mos(Q + 130, 175, "n", "XN33M", "4×4/2 33")
    s.line((Q - 40, 175), (Q - 40, 235), (Q + 90, 235), (Q + 90, 175), (Q + 100, 175)); s.dot(Q - 40, 175)
    s.line((Q + 145, 205), (Q + 145, 215)); s.gnd(Q + 145, 215)
    s.vdd(Q + 145, 30, "RX_VDD")
    s.mos(Q + 130, 75, "p", "XP33D", "4×16/2 33")
    s.line((Q + 145, 30), (Q + 145, 45))
    s.line((Q + 145, 105), (Q + 145, 145)); s.dot(Q + 145, 120)
    s.line((Q + 100, 75), (Q + 90, 75), (Q + 90, 120), (Q + 145, 120))
    s.line((Q + 145, 120), (Q + 260, 120), acc=True); s.pin(Q + 264, 120, "vbp33", "r", acc=True)
    s.text(Q + 80, 245, "XPD0..2: vbp18 → VDDO, n33 → 0, vbp33 → VDD when off", "middle", "sz")
    # level shifter
    L, Ly = X + 40, 360
    s.text(L + 160, Ly - 20, "RX_EN: XE0, XE1 (RX_VDDO), level shifter XL0..XL3 (RX_VDD)", "start", "lb")
    s.pin(L, Ly + 30, "RX_EN", "l"); s.line((L + 4, Ly + 30), (L + 15, Ly + 30))
    o = s.inv(L + 15, Ly + 30, "XE0", None, 20); s.line(o, (o[0] + 30, Ly + 30)); s.text(o[0] + 15, Ly + 50, "enb18", "middle", "sz")
    o = s.inv(o[0] + 30, Ly + 30, "XE1", None, 20); s.line(o, (L + 170, Ly + 30)); s.text(o[0] + 25, Ly + 50, "en18", "middle", "sz")
    s.box(L + 170, Ly + 5, 140, 50, "XL0..XL3", "cross-coupled pch33", )
    s.line((L + 310, Ly + 30), (L + 340, Ly + 30)); s.text(L + 344, Ly + 34, "en33, lsb (= !en33)", "start", "sz")
    # UVLO
    U = X + 600
    s.text(U + 120, Ly - 20, "UVLO", "middle", "lb")
    s.pin(U, Ly + 10, "RX_VDD", "l"); s.line((U + 4, Ly + 10), (U + 20, Ly + 10))
    s.box(U + 20, Ly - 5, 50, 30, "XU0", "lsb")
    s.line((U + 70, Ly + 10), (U + 90, Ly + 10))
    s.hres(U + 90, U + 150, Ly + 10, "RU1", "474 kΩ")
    s.dot(U + 150, Ly + 10); s.text(U + 150, Ly + 2, "vdiv", "middle", "sz")
    s.line((U + 150, Ly + 10), (U + 150, Ly + 30)); s.res(U + 150, Ly + 30, Ly + 80, "RU2", "100 kΩ", lab="l")
    s.gnd(U + 150, Ly + 80)
    s.line((U + 150, Ly + 10), (U + 190, Ly + 10))
    s.box(U + 190, Ly - 10, 80, 50, "rx_cmp XCU", "vuv < vdiv")
    s.text(U + 190, Ly + 62, "g1 = vuv = I0 · 25 kΩ (XU1, RUV)", "start", "sz")
    s.line((U + 270, Ly + 15), (U + 290, Ly + 15)); s.text(U + 294, Ly + 19, "pok", "start", "sz")
    return s


SHEETS = {"top": sheet_top, "hs": sheet_hs, "cmp": sheet_cmp, "dda": sheet_dda, "logic": sheet_logic,
          "bias": sheet_bias}

if __name__ == "__main__":
    for name, fn in SHEETS.items():
        sv = fn().svg()
        open(os.path.join(HERE, f"rx_{name}.svg"), "w").write(sv.replace("<defs>", STYLE + "<defs>", 1))
    print("written:", ", ".join(f"rx_{n}.svg" for n in SHEETS))
