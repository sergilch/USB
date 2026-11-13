#!/usr/bin/env python3
"""draw_transceiver.py - SVG schematic sheets of afe_transceiver_tr.sp (AFE/spice/afe_transceiver_tr.sp)

    python3 AFE/spice/doc/draw_transceiver.py      -> AFE/spice/doc/xc_*.svg

Same symbols and conventions as draw_cdr.py / draw_receiver.py (instance
names and sizes from the netlist, W/L in um, "m×" = multiplier).  Thick-oxide
3.3 V devices (pch33 / nch33) carry a "33" after the size; everything else is
a 1.8 V core device.  Accent colour: the signal path of the sheet.
"""
import os
from draw_cdr import Sheet, STYLE, HERE


def gate(s, x, y, name, sub=None, w=56, h=36, acc=False):
    """logic gate as a small box, inputs on the left, output (x + w, y + h / 2)"""
    s.box(x, y, w, h, name, sub, acc=acc)
    return (x + w, y + h / 2)


def shift(s, dx):
    """move everything right by dx (room for long pin names on the left edge)"""
    s.el = [f'<g transform="translate({dx},0)">'] + s.el + ['</g>']
    s.w += dx


# =========================================================== top level
def sheet_top():
    s = Sheet(1000, 600, "Top level: TX_IN_P/N and TX_EN drive the HS current driver (17.8 mA steered to DP, DM or a "
                         "dump), the FS / LS controls drive two slew-controlled push-pull drivers, three receivers "
                         "report the line, and switched resistors give the pull-up, the 45 Ohm terminations and the "
                         "pull-downs; logic on VDD18, everything on the line on VDD33")
    s.text(130, 16, "VDD18 (1.8 V): logic, pre-drivers, outputs", "middle", "lb")
    s.text(620, 16, "VDD33 (3.3 V): line side, thick oxide", "middle", "lb")
    s.line((300, 24), (300, 580), dash=True)
    # line buses
    for x, nm in ((880, "DP"), (930, "DM")):
        s.line((x, 40), (x, 540), acc=True)
        s.pin(x, 556, nm, "b", acc=True)
    # HS
    s.pin(-20, 60, "TX_IN_P", "tl", acc=True); s.pin(-20, 95, "TX_IN_N", "tl", acc=True)
    s.pin(-20, 130, "TX_EN", "tl")
    s.line((-16, 60), (70, 60), acc=True); s.line((-16, 95), (70, 95), acc=True); s.line((-16, 130), (70, 130))
    s.box(70, 45, 190, 100, "hs_tx: steering logic", "OAI21 + pre-drivers, ready", acc=True)
    s.text(165, 132, "timer 18.5 ns", "middle", "sz")
    s.arrow(260, 80, 420, 80, "gp, gn, gd (0..1.8 V)", acc=True)
    s.box(420, 40, 200, 110, "XS · XE · XSP/XSN/XSD", "17.8 mA, steering", acc=True)
    s.text(520, 128, "parked at VDD33 while off", "middle", "sz")
    s.line((620, 70), (880, 70), acc=True); s.dot(880, 70)
    s.line((620, 95), (930, 95), acc=True); s.dot(930, 95)
    s.text(750, 64, "17.8 mA into DP (J) or DM (K)", "middle", "ar")
    s.line((620, 125), (700, 125)); s.box(700, 106, 90, 38, "RDQ", "22.5 Ω")
    s.arrow(165, 145, 165, 175)
    s.box(70, 175, 190, 40, "XE0..XE5, ls_up", "TX_EN & pok → e33, e33b")
    s.line((260, 195), (520, 195), (520, 150))
    # bias
    s.pin(316, 250, "TX_VREF", "tl"); s.line((320, 250), (350, 250))
    s.box(350, 225, 190, 55, "xc_bias", "OTA + replica, I = VREF/12k")
    s.text(445, 296, "vbp (50 µA / unit), nb", "middle", "sz")
    s.line((445, 225), (445, 150))
    s.box(560, 225, 130, 55, "uvlo", "VDD33 > 2.94 V")
    s.text(625, 296, "pok", "middle", "sz")
    s.line((690, 252), (720, 252), (720, 310), (280, 310), (280, 200), (260, 200))
    # FS / LS
    s.pin(-20, 330, "FS_OE_A", "tl"); s.pin(-20, 355, "FS_DAT_A", "tl"); s.pin(-20, 380, "FS_SE0_A", "tl")
    s.pin(-20, 405, "FS_LS_A", "tl")
    for y in (330, 355, 380, 405):
        s.line((-16, y), (70, y))
    s.box(70, 320, 190, 95, "FS logic XF0..XF14", "J → DP (FS) / DM (LS),")
    s.text(165, 400, "SE0 overrides, & pok", "middle", "sz")
    s.arrow(260, 360, 360, 360, "u, d ×2, ls")
    s.box(360, 335, 120, 50, "ls_up ×5", "→ VDD33")
    s.arrow(480, 360, 560, 360)
    s.box(560, 330, 200, 60, "fs_drv XFP, XFM", "Miller slew, 34 Ω incl. RS")
    s.line((760, 350), (880, 350)); s.dot(880, 350)
    s.line((760, 372), (930, 372)); s.dot(930, 372)
    s.text(660, 408, "FS 10 ns / LS 120 ns edges", "middle", "sz")
    # receivers
    s.box(560, 430, 200, 60, "se_rx ×2, diff_rx", "Schmitt 1.26/1.60 V; rail-to-rail")
    s.line((880, 445), (760, 445)); s.dot(880, 445)
    s.line((930, 470), (760, 470)); s.dot(930, 470)
    s.arrow(560, 460, 470, 460, "sp, sm, sd")
    s.box(330, 435, 140, 50, "ls_dn ×3", "→ VDD18")
    s.arrow(330, 460, 260, 460)
    s.box(70, 430, 190, 60, "gating XR0..XR10", "& FS_RX_EN_A & pok")
    for y, nm in ((445, "RXDP_A"), (467, "RXDM_A"), (489, "RXRCV_A")):
        s.line((70, y), (-16, y)); s.pin(-20, y, nm, "tl")
    s.pin(-20, 530, "FS_RX_EN_A", "tl"); s.line((-16, 530), (165, 530), (165, 490))
    # terminations
    s.box(560, 510, 200, 50, "terminations", "1.5 kΩ up · 45 Ω · 15 kΩ down")
    s.line((760, 525), (880, 525)); s.dot(880, 525)
    s.line((760, 545), (930, 545)); s.dot(930, 545)
    s.pin(-20, 575, "DP_PULLUP_EN_A, HS_TERM_EN_A, PD_EN_A0, PD_EN_A1", "tl")
    s.line((-16, 575), (520, 575), (520, 535), (560, 535))
    return s


# =========================================================== HS output branch
def sheet_hs():
    s = Sheet(1000, 520, "HS output branch (VDD33): XS (356 units of 10/1, 17.8 mA, gate vbp) through the enable "
                         "switch XE into cs, steered by XSP to DP, XSN to DM or XSD to the 22.5 Ohm dump; CK cancels "
                         "the charge vbp loses when XE closes; while TX is off XKC and XKP/XKN/XKD park cs and the "
                         "switch gates at VDD33")
    s.vdd(330, 30, "VDD33")
    s.mos(315, 75, "p", "XS", "356×10/1 33")
    s.line((330, 30), (330, 45))
    s.pin(200, 75, "vbp", "l", acc=True); s.line((204, 75), (285, 75), acc=True)
    s.line((330, 105), (330, 125)); s.dot(330, 125); s.text(338, 122, "sd", "start", "sz")
    s.mos(315, 155, "p", "XE", "12×50/0.35 33")
    s.line((330, 125), (330, 125))
    s.pin(200, 155, "e33b", "l"); s.line((204, 155), (285, 155))
    s.line((330, 185), (330, 220)); s.dot(330, 220); s.text(340, 214, "cs (n-wells of XSP/XSN/XSD)", "start", "sz")
    s.line((170, 220), (530, 220), acc=True)
    for x, nm, g, out in ((170, "XSP", "gp", "DP"), (350, "XSN", "gn", "DM"), (530, "XSD", "gd", "dq")):
        s.res(x, 220, 270, "RS" + nm[2], "10 Ω")
        s.mos(x - 15, 300, "p", nm, "8×50/0.35 33")
        s.line((x - 45, 300), (x - 60, 300)); s.text(x - 64, 304, g, "end", "dev")
        s.line((x, 330), (x, 350), acc=(out != "dq"))
        if out == "dq":
            s.res(x, 350, 410, "RDQ", "22.5 Ω"); s.gnd(x, 410)
        else:
            s.pin(x, 354, out, "b", acc=True)
    s.text(350, 470, "RSP / RSN / RSD: degeneration, I·R = 0.18 V widens the transfer window", "middle", "sz")
    s.text(350, 435, "XSP on: rdy & (p | !n) · XSN on: rdy & (n | !p) · XSD on: !rdy", "middle", "ar")
    s.text(350, 452, "P = N opens XSP and XSN together: 8.9 mA each (model: half / half)", "middle", "sz")
    # CK
    s.cap(240, 30, 75, "CK", "1 pF", lab="l")
    s.line((240, 75), (240, 75)); s.dot(240, 75)
    s.line((240, 30), (240, 20), (120, 20)); s.pin(116, 20, "eb2 (= TX_EN, 3.3 V)", "l")
    s.text(-30, 490, "CK: eb2 steps +3.3 V on vbp when XS's drain falls out of triode (−1.6 V): cancels about 3 pC", "start", "sz")
    # parking
    X = 680
    s.text(X + 140, 40, "parking while TX_EN = 0 (e33 = 0)", "middle", "lb")
    s.vdd(X + 35, 70, "VDD33")
    s.mos(X + 20, 110, "p", "XKC", "10/0.35 33")
    s.line((X + 35, 70), (X + 35, 80))
    s.line((X - 10, 110), (X - 20, 110)); s.text(X - 24, 114, "e33", "end", "sz")
    s.line((X + 35, 140), (X + 35, 160)); s.text(X + 35, 175, "cs → VDD33", "middle", "dev")
    s.box(X, 200, 280, 60, "XKP, XKN, XKD (4/0.35 33)", "gp, gn, gd → VDD33")
    s.box(X, 290, 280, 75, "XTP, XTN, XTD: nch33 + pch33 TG", "12/0.35 33, e33 / e33b")
    s.text(X + 140, 352, "cut the 1.8 V pre-drivers off", "middle", "sz")
    s.text(X + 140, 395, "With FS / LS on the line (DP at 3.3 V)", "middle", "sz")
    s.text(X + 140, 410, "a switch gate at 1.8 V would conduct and", "middle", "sz")
    s.text(X + 140, 425, "the n-wells on cs would forward-bias:", "middle", "sz")
    s.text(X + 140, 440, "parked, every junction on DP / DM is", "middle", "sz")
    s.text(X + 140, 455, "reverse biased.", "middle", "sz")
    return s


# =========================================================== HS pre-driver and ready timer
def sheet_pre():
    s = Sheet(1000, 560, "HS steering logic and ready timer (VDD18): input buffers, OAI21 gates that open a switch "
                         "one inverter earlier than the other closes, final stages sinv that pull a switch gate down at "
                         "once (switch on) and up at 16 x 50 uA from the reference (switch off, sets the line edge), transmission gates to the switch gates; CR is discharged by about "
                         "5 uA once TX_EN and pok rise and hands the current from the dump to the line 18.5 ns later")
    y1, y2 = 70, 190
    s.pin(-20, y1, "TX_IN_P", "l", acc=True); s.pin(-20, y2, "TX_IN_N", "l", acc=True)
    s.line((-16, y1), (10, y1), acc=True); s.line((-16, y2), (10, y2), acc=True)
    o = s.inv(10, y1, "XI0", None, 22); s.line(o, (70, y1), acc=True); s.text(52, y1 - 8, "pb", "middle", "sz")
    o = s.inv(70, y1, "XI1", None, 22); s.line(o, (130, y1), acc=True); s.text(112, y1 - 8, "pq", "middle", "sz")
    o = s.inv(10, y2, "XI2", None, 22); s.line(o, (70, y2), acc=True); s.text(52, y2 + 22, "nbr", "middle", "sz")
    o = s.inv(70, y2, "XI3", None, 22); s.line(o, (130, y2), acc=True); s.text(112, y2 + 22, "nq", "middle", "sz")
    # cross connections: pq, nbr -> OAI P; nq, pb -> OAI N
    s.line((130, y1), (170, y1), acc=True)
    s.line((58, y2), (58, y1 + 30), (170, y1 + 30)); s.dot(58, y2)
    s.line((130, y2), (170, y2), acc=True)
    s.line((48, y1), (48, y2 - 30), (170, y2 - 30)); s.dot(48, y1)
    a = gate(s, 170, y1 - 10, "XGP", "OAI21", w=70, h=54, acc=True)
    b = gate(s, 170, y2 - 40, "XGN", "OAI21", w=70, h=54, acc=True)
    s.text(205, y1 + 62, "!(rdy & (p | !n))", "middle", "sz")
    s.text(205, y2 + 30, "!(rdy & (n | !p))", "middle", "sz")
    for (ox, oy), nm, nm2, g in ((a, "XBP0", "XBP1", "gp"), (b, "XBN0", "XBN1", "gn")):
        s.line((ox, oy), (ox + 15, oy), acc=True)
        o = s.inv(ox + 15, oy, nm, "1/2.5", 22); s.line(o, (o[0] + 20, oy), acc=True)
        o = s.inv(o[0] + 20, oy, nm2, "sinv", 26); s.line(o, (o[0] + 20, oy), acc=True)
        s.text(o[0] + 10, oy - 8, g + "i", "middle", "sz")
        t = s.tg(o[0] + 20, oy, "XT" + g[1].upper())
        s.line(t, (t[0] + 40, oy), acc=True); s.pin(t[0] + 44, oy, g + " → XS" + g[1].upper(), "r", acc=True)
    # dump gate
    yd = 280
    s.pin(380, yd, "rdy", "l"); s.line((384, yd), (400, yd))
    o = s.inv(400, yd, "XBD0", "1/2.5", 22); s.line(o, (o[0] + 20, yd))
    o = s.inv(o[0] + 20, yd, "XBD1", "sinv", 26); s.line(o, (o[0] + 20, yd))
    s.text(640, 145, "sinv: pfet 12 in series with XP2", "start", "sz")
    s.text(640, 160, "16×5/0.36 at pbs (pull-up 16 × 50 µA),", "start", "sz")
    s.text(640, 175, "nfet 6 to GND (pull-down at once);", "start", "sz")
    s.text(640, 190, "pbs: XB0 nch33 at nb → pfet diode XB1", "start", "sz")
    t = s.tg(o[0] + 20, yd, "XTD"); s.line(t, (t[0] + 40, yd)); s.pin(t[0] + 44, yd, "gd → XSD", "r")
    s.line((240, y1 + 30), (255, y1 + 30)); s.line((240, y2 - 3), (255, y2 - 3))
    s.text(160, 245, "rdy into XGP / XGN (third input)", "start", "sz")
    s.text(720, 420, "TGs: nch33 gate e33, pch33 gate e33b (12/0.35)", "middle", "sz")
    # ready timer
    Y = 360
    s.text(140, Y - 30, "ready timer", "middle", "lb")
    s.vdd(160, Y - 10, "VDD18")
    s.mos(145, Y + 25, "p", "XT0", "1/0.18")
    s.line((160, Y - 10), (160, Y - 5))
    s.pin(60, Y + 25, "en", "l"); s.line((64, Y + 25), (115, Y + 25)); s.line((90, Y + 25), (90, Y + 75), (115, Y + 75))
    s.dot(90, Y + 25)
    s.line((160, Y + 55), (160, Y + 45)); s.dot(160, Y + 50)
    s.mos(145, Y + 75, "n", "XT1", "1/0.18")
    s.line((160, Y + 105), (160, Y + 115)); s.text(168, Y + 112, "ct", "start", "sz")
    s.mos(145, Y + 145, "n", "XTS", "1/2 33")
    s.line((115, Y + 145), (90, Y + 145)); s.text(86, Y + 149, "nb", "end", "dev")
    s.line((160, Y + 175), (160, Y + 182)); s.gnd(160, Y + 182)
    s.line((160, Y + 50), (230, Y + 50)); s.cap(230, Y + 50, Y + 95, "CR", "0.1 pF"); s.gnd(230, Y + 95)
    s.text(232, Y + 44, "cr", "middle", "sz")
    s.text(240, Y + 150, "XTS: about 5 µA", "start", "sz")
    s.line((230, Y + 50), (300, Y + 50))
    o = s.inv(300, Y + 50, "XT2", None, 22); s.line(o, (380, Y + 50)); s.text(355, Y + 42, "rb", "middle", "sz")
    g = gate(s, 380, Y + 32, "XT3", "NAND2", w=60)
    s.line((370, Y + 25), (370, Y + 40), (380, Y + 40)); s.text(366, Y + 22, "en", "end", "sz")
    s.line(g, (g[0] + 15, g[1]))
    o = s.inv(g[0] + 15, g[1], "XT4", None, 22); s.line(o, (o[0] + 20, g[1])); s.pin(o[0] + 24, g[1], "rdy", "r")
    s.text(600, Y + 125, "cr falls to VDD18 / 2 in 0.1 pF · 0.9 V / 5 µA ≈ 18.5 ns; TX_EN falls: rdy = 0 at once", "middle", "ar")
    shift(s, 80)
    return s


# =========================================================== bias and UVLO
def sheet_bias():
    s = Sheet(1000, 480, "Bias and UVLO (VDD33): the OTA forces V(fb) = V(TX_VREF) on RREF through a 2/356 replica of "
                         "the HS branch (XR, XRE, XRS), so XS carries 178 x 100 uA at the same drain voltage; vbp "
                         "and nb bias every source in the block; UVLO compares VDD33 through a divider with TX_VREF")
    # tail bias: RT into the diode XT1, mirrored by XO0
    s.vdd(20, 200, "VDD33")
    s.res(20, 200, 270, "RT", "12 kΩ")
    s.line((20, 270), (20, 300)); s.dot(20, 290)
    s.mos(35, 330, "n", "XT1", "4/1 33", mirror=True)
    s.line((20, 290), (55, 290), (55, 330)); s.dot(55, 330)
    s.line((20, 360), (20, 370)); s.gnd(20, 370)
    s.line((65, 330), (115, 330))
    # OTA
    s.vdd(160, 60, "VDD33")
    s.line((120, 60), (200, 60)); s.line((120, 60), (120, 90)); s.line((200, 60), (200, 90))
    s.mos(135, 120, "p", "XO3", "20/0.5 33", mirror=True)
    s.mos(185, 120, "p", "XO4", "20/0.5 33")
    s.line((165, 120), (155, 120)); s.dot(160, 120)
    s.line((160, 120), (160, 160), (120, 160)); s.dot(120, 160); s.text(114, 175, "o1", "end", "sz")
    s.line((120, 150), (120, 220)); s.line((200, 150), (200, 220)); s.dot(200, 180)
    s.mos(105, 250, "n", "XO1", "20/0.5 33")
    s.mos(215, 250, "n", "XO2", "20/0.5 33", mirror=True, lab="l")
    s.line((120, 280), (200, 280)); s.dot(160, 280); s.text(168, 294, "ot", "start", "sz")
    s.line((160, 280), (160, 300))
    s.mos(145, 330, "n", "XO0", "4/1 33")
    s.line((160, 360), (160, 370)); s.gnd(160, 370)
    s.line((245, 250), (245, 285), (290, 285)); s.pin(294, 285, "TX_VREF", "r", acc=True)
    s.text(150, 470, "OTA, tail about 200 µA (RT, XT1, XO0)", "middle", "ar")
    # vbp to the replica and out
    s.line((200, 180), (320, 180), (320, 80), (335, 80), acc=True); s.text(260, 174, "vbp", "middle", "dev")
    s.line((320, 80), (320, 40), (520, 40), (520, 85), (535, 85), acc=True); s.dot(320, 80)
    # replica
    X = 380
    s.vdd(X, 30, "VDD33")
    s.line((X, 30), (X, 50))
    s.mos(X - 15, 80, "p", "XR", "2×10/1 33")
    s.text(X + 8, 118, "rd", "start", "sz")
    s.mos(X - 15, 150, "p", "XRE", "3.4/0.35 33")
    s.line((X, 110), (X, 120))
    s.mos(X - 15, 220, "p", "XRS", "2.25/0.35 33")
    s.line((X, 180), (X, 190)); s.text(X + 8, 188, "rx", "start", "sz")
    s.line((X - 45, 150), (X - 50, 150), (X - 50, 240)); s.line((X - 45, 220), (X - 50, 220)); s.dot(X - 50, 220)
    s.gnd(X - 50, 240)
    s.line((X, 250), (X, 280)); s.dot(X, 280); s.text(X + 8, 296, "fb", "start", "dev")
    s.line((X, 280), (X + 60, 280)); s.res(X + 60, 280, 350, "RREF", "12 kΩ"); s.gnd(X + 60, 350)
    s.line((X, 280), (X, 400), (75, 400), (75, 250))
    s.text(X + 40, 430, "I = V(TX_VREF) / RREF = 100 µA", "middle", "ar")
    s.text(X + 40, 447, "XRE, XRS: gates at 0 V, like XE / XSP when on", "middle", "sz")
    # nb
    N = 580
    s.vdd(N, 30, "VDD33")
    s.line((N, 30), (N, 55))
    s.mos(N - 15, 85, "p", "XNB", "10/1 33")
    s.line((N, 115), (N, 135)); s.dot(N, 130)
    s.mos(N - 15, 165, "n", "XND", "5/1 33")
    s.line((N - 45, 165), (N - 55, 165), (N - 55, 130), (N, 130))
    s.line((N, 195), (N, 205)); s.gnd(N, 205)
    s.line((N, 130), (N + 40, 130)); s.pin(N + 44, 130, "nb", "r")
    s.pin(N + 44, 40, "vbp", "r", acc=True); s.line((520, 40), (N + 40, 40), acc=True); s.dot(520, 40)
    s.text(N + 20, 240, "nb: nch33 5/1 sinks 50 µA", "middle", "sz")
    s.text(N + 20, 256, "vbp: pch33 10/1 sources 50 µA", "middle", "sz")
    # UVLO
    U = 740
    s.text(U + 130, 280, "UVLO", "middle", "lb")
    s.vdd(U, 300, "VDD33")
    s.res(U, 300, 350, "RU1", "290 kΩ", lab="l"); s.dot(U, 350); s.text(U + 8, 344, "tap", "start", "sz")
    s.res(U, 350, 400, "RU2", "200 kΩ", lab="l"); s.dot(U, 400)
    s.res(U, 400, 445, "RUH", "10 kΩ", lab="l"); s.gnd(U, 445)
    s.line((U, 400), (U + 30, 400)); s.box(U + 30, 385, 60, 30, "XUH", None)
    s.text(U + 60, 430, "gate pokb", "middle", "sz")
    s.line((U + 90, 400), (U + 100, 400), (U + 100, 445)); s.gnd(U + 100, 445)
    s.line((U, 350), (U + 130, 350))
    s.box(U + 130, 320, 120, 60, "XU1..XU4, XUT", "nch33 pair, 10 µA")
    s.text(U + 190, 395, "tap vs TX_VREF", "middle", "sz")
    s.line((U + 250, 350), (U + 260, 350)); s.pin(U + 264, 350, "pok", "r")
    s.text(U + 120, 472, "on above 2.94 V, off below 2.86 V", "middle", "ar")
    return s


# =========================================================== FS / LS driver
def sheet_fs():
    s = Sheet(1000, 500, "FS / LS driver, one wire (VDD33): push-pull XMP / XMN with RS 26 Ohm; Miller capacitors CMP "
                         "/ CMN from the drain o to each gate set the slew: a gate turns on through a current source "
                         "(LS: a 5/2 mirror of nb; FS adds 7 x 50 uA) and off at once through XPO / XNO, so the two devices "
                         "never conduct together")
    X = 560
    s.vdd(X, 40, "VDD33")
    s.mos(X - 15, 110, "p", "XMP", "14×40/0.35 33")
    s.line((X, 40), (X, 80))
    s.line((X, 140), (X, 270)); s.dot(X, 230)
    s.mos(X - 15, 300, "n", "XMN", "6×40/0.35 33")
    s.line((X, 330), (X, 345)); s.gnd(X, 345)
    s.line((X, 230), (X + 80, 230), acc=True); s.text(X + 10, 222, "o", "start", "dev")
    s.hres(X + 80, X + 160, 230, "RS", "26 Ω")
    s.line((X + 160, 230), (X + 200, 230), acc=True); s.pin(X + 204, 230, "DP / DM", "r", acc=True)
    # gates and Miller caps (CM between the gate and o)
    C = X - 70
    s.line((X - 45, 110), (300, 110)); s.dot(C, 110); s.text(C + 18, 104, "gp", "middle", "dev")
    s.line((X - 45, 300), (300, 300)); s.dot(C, 300); s.text(C + 18, 318, "gn", "middle", "dev")
    s.line((C, 110), (C, 145)); s.cap(C, 145, 195, "CMP", "1 pF", lab="l"); s.line((C, 195), (C, 230))
    s.line((C, 230), (X, 230)); s.dot(C, 230)
    s.line((C, 230), (C, 245)); s.cap(C, 245, 285, "CMN", "1 pF", lab="l"); s.line((C, 285), (C, 300))
    s.line((C - 80, 300), (C - 80, 330)); s.dot(C - 80, 300)
    s.cap(C - 80, 330, 370, "CGB", "0.5 pF", lab="l"); s.gnd(C - 80, 370)
    s.text(X + 120, 275, "output slope I / CM (+ Cgd)", "middle", "ar")
    # gp drive
    G = 230
    s.vdd(G + 15, 40, "VDD33")
    s.mos(G, 70, "p", "XPO", "20/0.35 33")
    s.line((G - 30, 70), (G - 45, 70)); s.text(G - 49, 74, "u", "end", "dev")
    s.line((G + 15, 100), (G + 15, 110)); s.dot(G + 15, 110); s.line((G + 15, 110), (300, 110))
    s.box(20, 130, 200, 60, "XPN (gate u) · XPLS", "LS sink: nch33 5/2 at nb")
    s.text(120, 205, "XPFS (gate fs) + XPFI 7×5/1: +350 µA for FS", "middle", "sz")
    s.line((220, 160), (G + 15, 160), (G + 15, 110))
    s.text(120, 118, "gp falls (pull-up on) when u = 1", "middle", "ar")
    # gn drive
    s.box(20, 270, 200, 60, "XNP (gate db) · XNLS", "LS source: pch33 10/2 at vbp")
    s.text(120, 345, "XNFS (gate fsb) + XNFI 7×10/1: +350 µA", "middle", "sz")
    s.text(120, 258, "gn rises (pull-down on) when d = 1", "middle", "ar")
    s.line((220, 300), (300, 300))
    s.mos(G, 410, "n", "XNO", "10/0.35 33")
    s.line((G + 15, 380), (G + 15, 300)); s.dot(G + 15, 300)
    s.line((G - 30, 410), (G - 45, 410)); s.text(G - 49, 414, "db", "end", "dev")
    s.line((G + 15, 440), (G + 15, 450)); s.gnd(G + 15, 450)
    # control table
    T = 740
    s.text(T + 110, 350, "control (FS logic XF0..XF14, VDD18)", "middle", "lb")
    rows = [("OE = 0 or !pok", "u = d = 0: off"), ("SE0 = 1", "both wires low"), ("DAT xor LS = 1", "DP high"),
            ("DAT xor LS = 0", "DM high"), ("LS = 1", "FS sources off")]
    for i, (a, b) in enumerate(rows):
        s.text(T, 372 + 17 * i, a, "start", "sz"); s.text(T + 125, 372 + 17 * i, b, "start", "sz")
    s.text(T + 110, 470, "u, d, ls → ls_up → VDD33", "middle", "sz")
    return s


# =========================================================== receivers
def sheet_rx():
    s = Sheet(1150, 500, "Receivers (VDD33): CMOS Schmitt triggers for RXDP_A / RXDM_A (1.26 / 1.60 V) and a "
                         "rail-to-rail comparator for RXRCV_A: a PMOS and an NMOS pair, the currents that grow for a above b summed "
                         "in XP5 and mirrored up by XP7, the others summed in XN5 and mirrored down by XN8, "
                         "switched-current hysteresis; outputs down-shifted to VDD18")
    # Schmitt
    s.text(0, 30, "se_rx (×2)", "start", "lb")
    s.vdd(115, 30, "VDD33")
    s.mos(100, 70, "p", "XP1", "2.5 33"); s.line((115, 30), (115, 40))
    s.mos(100, 140, "p", "XP2", "2.5 33")
    s.line((115, 100), (115, 110)); s.dot(115, 105); s.text(123, 102, "x1", "start", "sz")
    s.line((115, 170), (115, 200)); s.dot(115, 185)
    s.mos(100, 230, "n", "XN2", "2.5 33")
    s.mos(100, 300, "n", "XN1", "2.5 33")
    s.line((115, 260), (115, 270)); s.dot(115, 265); s.text(123, 268, "x2", "start", "sz")
    s.line((115, 330), (115, 340)); s.gnd(115, 340)
    s.line((70, 70), (40, 70), (40, 300), (70, 300), acc=True)
    s.line((40, 140), (70, 140), acc=True); s.line((40, 230), (70, 230), acc=True)
    s.dot(40, 140); s.dot(40, 230); s.dot(40, 185)
    s.pin(-10, 185, "DP", "l", acc=True); s.line((-6, 185), (40, 185), acc=True)
    s.line((115, 185), (200, 185)); s.text(160, 180, "yb", "middle", "sz")
    s.text(130, 400, "XP3 0.8: x1 → GND, XN3 0.8: x2 → VDD33 (gates yb)", "middle", "sz")
    o = s.inv(200, 185, "XO", None, 22); s.line(o, (260, 185)); s.pin(264, 185, "sp33", "r")
    s.text(130, 380, "high above 1.60 V, low below 1.26 V (tt)", "middle", "ar")
    # diff_rx
    X = 400
    s.text(X + 260, 16, "diff_rx", "middle", "lb")
    s.vdd(X + 100, 30, "VDD33")
    s.mos(X + 85, 60, "p", "XPT", "10/1 33"); s.line((X + 100, 30), (X + 100, 30))
    s.line((X + 55, 60), (X + 40, 60)); s.text(X + 36, 64, "vbp", "end", "sz")
    s.line((X + 100, 90), (X + 100, 100)); s.line((X + 20, 100), (X + 180, 100))
    s.mos(X + 5, 130, "p", "XP1", "20/0.5 33", lab="r")
    s.mos(X + 195, 130, "p", "XP2", "20/0.5 33", mirror=True, lab="r")
    s.line((X + 20, 100), (X + 20, 100))
    s.line((X + 20, 160), (X + 20, 200)); s.dot(X + 20, 200); s.text(X + 14, 214, "d1p", "end", "dev")
    s.line((X + 180, 160), (X + 180, 200)); s.dot(X + 180, 200); s.text(X + 186, 214, "d2p", "start", "dev")
    s.text(X + 100, 235, "XN5 / XN6: nch33 diodes 8/0.5", "middle", "sz")
    s.line((X - 25, 130), (X - 35, 130)); s.text(X - 39, 134, "a", "end", "pin")
    s.line((X + 225, 130), (X + 235, 130)); s.text(X + 239, 134, "b", "start", "pin")
    # NMOS pair
    Y = 330
    s.text(X + 100, Y - 40, "XP5 / XP6: pch33 diodes 16/0.5", "middle", "sz")
    s.line((X + 20, Y - 20), (X + 20, Y - 30)); s.dot(X + 20, Y - 20); s.text(X + 14, Y - 14, "d1n", "end", "dev")
    s.line((X + 180, Y - 20), (X + 180, Y - 30)); s.dot(X + 180, Y - 20); s.text(X + 186, Y - 14, "d2n", "start", "dev")
    s.mos(X + 5, Y + 10, "n", "XN1", "10/0.5 33", lab="r")
    s.line((X - 25, Y + 10), (X - 35, Y + 10)); s.text(X - 39, Y + 14, "a", "end", "pin")
    s.line((X + 225, Y + 10), (X + 235, Y + 10)); s.text(X + 239, Y + 14, "b", "start", "pin")
    s.mos(X + 195, Y + 10, "n", "XN2", "10/0.5 33", mirror=True, lab="r")
    s.line((X + 20, Y - 20), (X + 20, Y - 20))
    s.line((X + 20, Y + 40), (X + 20, Y + 50), (X + 180, Y + 50), (X + 180, Y + 40))
    s.box(X + 55, Y + 65, 90, 40, "XNT", "nb, 50 µA")
    s.line((X + 100, Y + 50), (X + 100, Y + 65))
    # summing and output
    O = X + 300
    s.box(O, 150, 160, 60, "XN7: I(XP2) → d1n", "gate d2p")
    s.box(O, 260, 160, 60, "XP8: I(XN2) → d1p", "gate d2n")
    s.line((X + 180, 200), (O, 200)); s.line((X + 180, Y - 20), (O - 20, Y - 20), (O - 20, 290), (O, 290))
    P = O + 250
    s.vdd(P, 40, "VDD33")
    s.mos(P - 15, 80, "p", "XP7", "16/0.5 33")
    s.line((P, 40), (P, 50))
    s.line((P - 45, 80), (P - 60, 80)); s.text(P - 64, 84, "d1n", "end", "dev")
    s.line((P, 110), (P, 270)); s.dot(P, 230)
    s.mos(P - 15, 300, "n", "XN8", "8/0.5 33")
    s.line((P, 330), (P, 340)); s.gnd(P, 340)
    s.line((P - 45, 300), (P - 60, 300)); s.text(P - 64, 304, "d1p", "end", "dev")
    s.line((P, 230), (P + 30, 230), acc=True); s.text(P + 15, 222, "o", "middle", "dev")
    o = s.inv(P + 30, 230, None, None, 18); o = s.inv(o[0] + 6, 230, None, None, 18)
    s.line(o, (o[0] + 10, 230), acc=True); s.pin(o[0] + 14, 230, "sd33", "r", acc=True)
    s.text(O + 85, 380, "up: I(XN1) + I(XP2) via XP7 · down: I(XP1) + I(XN2) via XN8", "middle", "ar")
    s.text(O + 85, 398, "XHP / XHN: ±12 µA into o following the output (hysteresis 45 .. 100 mV)", "middle", "sz")
    s.text(O + 85, 416, "PMOS pair works down to 0 V common mode, NMOS pair up to VDD33", "middle", "sz")
    s.text(560, 470, "ls_dn (nch33 1 / pch33 2 inverter on VDD18) → gating with FS_RX_EN_A & pok → RXDP_A, RXDM_A, RXRCV_A", "middle", "sz")
    return s


# =========================================================== terminations and level shifters
def sheet_term():
    s = Sheet(1140, 480, "Terminations and level shifters: pull-up XPU + RPU (1.49 kOhm), 45 Ohm HS terminations "
                         "XHP / XHM + 41.6 Ohm, 15 kOhm pull-downs XP0 / XP1 + 14 kOhm, each gate from a 1.8 to 3.3 V "
                         "level shifter; ls_up (cross-coupled pch33, nch33 pull-downs) and ls_dn (thick-oxide "
                         "inverter on VDD18)")
    # pull-up
    s.vdd(80, 30, "VDD33")
    s.mos(65, 70, "p", "XPU", "60/0.35 33"); s.line((80, 30), (80, 40))
    s.line((35, 70), (20, 70)); s.text(16, 74, "pug", "end", "dev")
    s.res(80, 100, 170, "RPU", "1.405 kΩ"); s.line((80, 170), (80, 200), acc=True); s.pin(80, 204, "DP", "b", acc=True)
    s.text(80, 245, "on: pug = 0 V", "middle", "sz")
    # HS terms
    for x, nm, sw, pin in ((280, "RHP", "XHP", "DP"), (470, "RHM", "XHM", "DM")):
        s.pin(x, 40, pin, "t", acc=True); s.line((x, 44), (x, 60), acc=True)
        s.res(x, 60, 130, nm, "41.6 Ω")
        s.mos(x - 15, 165, "n", sw, "13×40/0.35 33")
        s.line((x - 45, 165), (x - 60, 165)); s.text(x - 64, 169, "hsg", "end", "dev")
        s.line((x, 130), (x, 135)); s.line((x, 195), (x, 205)); s.gnd(x, 205)
    s.text(375, 245, "45.0 Ω at 0.2 .. 0.4 V (switch 3.4 Ω)", "middle", "sz")
    # pull-downs
    for x, nm, sw, pin, g in ((660, "RP0", "XP0", "DP", "pd0g"), (840, "RP1", "XP1", "DM", "pd1g")):
        s.pin(x, 40, pin, "t"); s.line((x, 44), (x, 60))
        s.res(x, 60, 130, nm, "14 kΩ")
        s.mos(x - 15, 165, "n", sw, "2/0.35 33")
        s.line((x - 45, 165), (x - 60, 165)); s.text(x - 64, 169, g, "end", "dev")
        s.line((x, 130), (x, 135)); s.line((x, 195), (x, 205)); s.gnd(x, 205)
    s.text(750, 245, "14.65 kΩ in total", "middle", "sz")
    s.text(1030, 60, "gate drive:", "middle", "lb")
    s.text(1030, 80, "DP_PULLUP_EN_A → ls_up XT0,", "middle", "sz")
    s.text(1030, 95, "XT1/XT2 → pug", "middle", "sz")
    s.text(1030, 115, "HS_TERM_EN_A → ls_up XT3,", "middle", "sz")
    s.text(1030, 130, "XT4/XT5 → hsg", "middle", "sz")
    s.text(1030, 150, "PD_EN_A0/1 → ls_up XT6/XT7", "middle", "sz")
    # ls_up
    Y = 290
    s.text(160, Y, "ls_up: a (VDD18) → y = a, yb = !a (VDD33)", "middle", "lb")
    s.vdd(110, Y + 20, "VDD33"); s.vdd(230, Y + 20, "VDD33")
    s.mos(125, Y + 55, "p", "XL2", "1/0.5 33", mirror=True, lab="r")
    s.mos(215, Y + 55, "p", "XL3", "1/0.5 33")
    s.line((110, Y + 20), (110, Y + 25)); s.line((230, Y + 20), (230, Y + 25))
    s.line((110, Y + 85), (110, Y + 100)); s.line((230, Y + 85), (230, Y + 100))
    s.line((155, Y + 55), (230, Y + 95)); s.line((185, Y + 55), (110, Y + 95))
    s.dot(110, Y + 95); s.dot(230, Y + 95)
    s.text(102, Y + 92, "yb", "end", "dev"); s.text(238, Y + 92, "y", "start", "dev")
    s.text(170, Y + 120, "XL0 (gate a) / XL1 (gate !a): nch33 2/0.35 to GND", "middle", "sz")
    # ls_dn
    s.text(560, Y, "ls_dn: a (VDD33) → y = !a (VDD18)", "middle", "lb")
    s.vdd(560, Y + 20, "VDD18")
    s.mos(545, Y + 55, "p", "XP", "2/0.35 33"); s.line((560, Y + 20), (560, Y + 25))
    s.mos(545, Y + 115, "n", "XN", "1/0.35 33")
    s.line((560, Y + 85), (560, Y + 85)); s.dot(560, Y + 85)
    s.line((515, Y + 55), (490, Y + 55), (490, Y + 115), (515, Y + 115)); s.dot(490, Y + 85)
    s.line((470, Y + 85), (490, Y + 85)); s.text(466, Y + 89, "a", "end", "dev")
    s.line((560, Y + 85), (600, Y + 85)); s.text(604, Y + 89, "y", "start", "dev")
    s.line((560, Y + 145), (560, Y + 150)); s.gnd(560, Y + 150)
    s.text(800, Y + 70, "thick-oxide gates take 0 .. 3.3 V;", "middle", "sz")
    s.text(800, Y + 85, "the output swings 0 .. VDD18", "middle", "sz")
    return s


SHEETS = {"top": sheet_top, "hs": sheet_hs, "pre": sheet_pre, "bias": sheet_bias, "fs": sheet_fs,
          "rx": sheet_rx, "term": sheet_term}

if __name__ == "__main__":
    for name, fn in SHEETS.items():
        sv = fn().svg()
        open(os.path.join(HERE, f"xc_{name}.svg"), "w").write(sv.replace("<defs>", STYLE + "<defs>", 1))
    print("written:", ", ".join(f"xc_{n}.svg" for n in SHEETS))
