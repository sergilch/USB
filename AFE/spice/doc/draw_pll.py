#!/usr/bin/env python3
"""draw_pll.py - SVG schematic sheets of afe_pll_tr.sp (AFE/spice/afe_pll_tr.sp)

    python3 AFE/spice/doc/draw_pll.py      -> AFE/spice/doc/pll_*.svg

Same symbols and conventions as draw_cdr.py.  The charge pump (n = 2) and the
VCO are the shared cells of afe_cells.sp: pll_cp.svg is drawn with n = 2, the
VCO sheet is cdr_vco.svg (identical cell).
"""
import os
from draw_cdr import Sheet, STYLE, sheet_cp, HERE


def sheet_top():
    s = Sheet(1000, 430, "PLL loop: CDR_FREF through the PFD and charge pump into the R2/C3/C4 filter on CDR_CH_OUT_PLL, "
                         "which tunes the shared VCO; INV3 clocks the divide-by-20/25 feedback divider back into the PFD")
    s.pin(-20, 90, "CDR_FREF", "tl", acc=True)
    s.line((-16, 90), (40, 90), acc=True); s.dot(40, 90)
    s.box(60, 70, 70, 40, "XF0, XF2", "ref_i")
    s.line((40, 90), (60, 90), acc=True)
    s.line((40, 90), (40, 30), (60, 30))
    s.box(60, 12, 70, 36, "XF0, XF1", None)
    s.line((130, 30), (170, 30)); s.pin(174, 30, "REF_DIG (always on)", "r")
    s.arrow(130, 90, 180, 90, "ref_i", acc=True)
    s.box(180, 70, 140, 90, "pll_pfd", "2 TSPC FF, reset 200 ps", acc=True)
    s.arrow(320, 95, 410, 95, "up / upb", acc=True)
    s.arrow(320, 130, 410, 130, "dn / dnb", acc=True)
    s.box(410, 75, 130, 75, "cdr_cp (n = 2)", "ICP 20 µA, steering", acc=True)
    s.line((540, 112), (660, 112), acc=True); s.dot(660, 112)
    s.pin(660, 40, "CDR_CH_OUT_PLL", "t", acc=True); s.line((660, 44), (660, 112))
    s.text(668, 62, "→ CDR_V_IN_2 of the CDR", "start", "ar")
    s.cap(600, 112, 170, "C4", "1.53 pF")
    s.gnd(600, 170)
    s.line((660, 112), (740, 112))
    s.res(740, 112, 165, "R2", "34.5 kΩ")
    s.cap(740, 165, 200, "C3", "15.1 pF")
    s.gnd(740, 200)
    s.text(734, 167, "nz", "end", "sz")
    s.line((660, 112), (660, 265), (600, 265), acc=True)
    s.text(666, 255, "coarse", "start", "ar")
    s.box(440, 240, 160, 75, "vco_v2i", "same cell as the CDR", acc=True)
    s.box(820, 240, 120, 75, "vref", "VDD/2, 2 × 100 kΩ")
    s.line((820, 290), (600, 290)); s.text(710, 284, "fine", "middle", "ar")
    s.arrow(440, 262, 360, 262, "vcp", acc=True)
    s.arrow(440, 295, 360, 295, "vcn", acc=True)
    s.box(200, 240, 160, 75, "vco_ring", "5 starved stages", acc=True)
    s.line((200, 278), (150, 278), acc=True); s.text(156, 271, "n5", "start", "sz")
    x, y = 60, 375
    s.line((150, 278), (150, 335), (40, 335), (40, y), (x, y), acc=True)
    o = s.inv(x, y, "INV1", None, 24)
    o = s.inv(o[0] + 10, y, "INV2", None, 24); s.line((o[0], y), (o[0] + 10, y))
    o = s.inv(o[0] + 10, y, "INV3", None, 24)
    ck = o[0] + 14
    s.line((o[0], y), (ck, y), acc=True); s.dot(ck, y)
    s.line((ck, y), (ck + 20, y))
    o = s.inv(ck + 20, y, "INV4", None, 24)
    o = s.inv(o[0] + 10, y, "INV5", None, 24)
    s.line((o[0], y), (o[0] + 30, y), acc=True)
    s.pin(o[0] + 34, y, "CLK_BIT_A", "r", acc=True)
    # divider
    s.line((ck, y), (ck, 410), (520, 410), acc=True); s.text(ck + 6, 404, "ckd (480 MHz)", "start", "ar")
    s.box(520, 385, 150, 40, "pll_div", "÷5 → ÷4 / ÷5", acc=True)
    s.line((560, 385), (560, 342), (170, 342), (170, 175), (220, 175), (220, 160), acc=True)
    s.text(380, 336, "fb (24 / 19.2 MHz)", "middle", "ar")
    s.pin(760, 415, "REFSEL1/0", "r"); s.line((756, 415), (735, 415))
    s.box(705, 400, 30, 30, "NOR", None)
    s.text(720, 445, "sel5", "middle", "sz")
    s.line((705, 420), (670, 420))
    s.pin(870, 170, "PLL_EN", "t"); s.line((870, 174), (870, 190))
    s.box(830, 190, 80, 36, "XE0, XE1", "en / enb")
    s.box(820, 340, 120, 40, "cdr_bias", "β-mult 10 µA")
    return s


def sheet_pfd():
    s = Sheet(1000, 330, "PFD: two TSPC flip-flops with D = 1; ref sets UP, fb sets DN; when both are set, NAND and two "
                         "inverters reset both after about 200 ps; PLL_EN = 0 holds the reset")
    # TSPC flip-flop at transistor level
    x = 120
    s.text(x + 100, 14, "pfd_ff (×2)", "middle", "lb")
    s.vdd(x + 40, 40); s.vdd(x + 200, 40)
    s.mos(x + 25, 80, "p", "XP2", "2/0.18")
    s.line((x + 40, 40), (x + 40, 50)); s.line((x - 5, 80), (x - 20, 80)); s.text(x - 24, 84, "rst", "end", "sz")
    s.mos(x + 25, 140, "p", "XP1", "2/0.18")
    s.line((x + 40, 110), (x + 40, 110))
    s.line((x - 5, 140), (x - 20, 140)); s.text(x - 24, 144, "ck", "end", "pin")
    s.dot(x + 40, 180); s.text(x + 48, 196, "n1", "start", "dev")
    s.line((x + 40, 170), (x + 40, 190))
    s.mos(x + 25, 220, "n", "XN2", "1/0.18")
    s.line((x - 5, 220), (x - 20, 220)); s.text(x - 24, 224, "rst", "end", "sz")
    s.line((x + 40, 250), (x + 40, 260)); s.gnd(x + 40, 260)
    s.mos(x + 185, 80, "p", "XP3", "2/0.18")
    s.line((x + 200, 40), (x + 200, 50))
    s.line((x + 155, 80), (x + 120, 80), (x + 120, 180), (x + 40, 180))
    s.line((x + 200, 110), (x + 200, 140)); s.dot(x + 200, 125)
    s.line((x + 200, 125), (x + 290, 125), acc=True); s.text(x + 294, 129, "qb", "start", "pin")
    s.mos(x + 185, 170, "n", "XN4", "2/0.18")
    s.line((x + 155, 170), (x + 140, 170)); s.text(x + 136, 174, "ck", "end", "sz")
    s.mos(x + 185, 230, "n", "XN5", "2/0.18")
    s.line((x + 200, 200), (x + 200, 200))
    s.line((x + 155, 230), (x + 120, 230), (x + 120, 180)); s.dot(x + 120, 180)
    s.line((x + 200, 260), (x + 200, 270)); s.gnd(x + 200, 270)
    # reset logic
    x0 = 560
    s.box(x0, 40, 80, 50, "pfd_ff", "ck = ref_i")
    s.box(x0, 160, 80, 50, "pfd_ff", "ck = fb")
    s.pin(x0 - 30, 65, "ref_i", "l", acc=True); s.line((x0 - 26, 65), (x0, 65), acc=True)
    s.pin(x0 - 30, 185, "fb", "l", acc=True); s.line((x0 - 26, 185), (x0, 185), acc=True)
    o = s.inv(x0 + 100, 65, "XIU", None, 22); s.line((x0 + 80, 65), (x0 + 100, 65), acc=True)
    s.line(o, (x0 + 220, 65), acc=True); s.pin(x0 + 224, 65, "up (upb via XIUB)", "r", acc=True)
    o2 = s.inv(x0 + 100, 185, "XID", None, 22); s.line((x0 + 80, 185), (x0 + 100, 185), acc=True)
    s.line(o2, (x0 + 220, 185), acc=True); s.pin(x0 + 224, 185, "dn (dnb via XIDB)", "r", acc=True)
    s.dot(x0 + 160, 65); s.dot(x0 + 160, 185)
    s.line((x0 + 160, 65), (x0 + 160, 110), (x0 + 175, 110))
    s.line((x0 + 160, 185), (x0 + 160, 130), (x0 + 175, 130))
    s.box(x0 + 175, 100, 50, 40, "XR0", "NAND")
    s.line((x0 + 225, 120), (x0 + 245, 120))
    s.box(x0 + 245, 105, 60, 30, "XR1, XR2", None)
    s.line((x0 + 305, 120), (x0 + 320, 120))
    s.box(x0 + 320, 100, 60, 40, "XR3", "NAND en")
    s.line((x0 + 380, 120), (x0 + 400, 120), (x0 + 400, 290), (x0 + 40, 290), (x0 + 40, 210))
    s.line((x0 + 40, 290), (x0 - 10, 290), (x0 - 10, 110), (x0 + 40, 110), (x0 + 40, 90))
    s.text(x0 + 200, 284, "rst = (up & dn) delayed, or PLL_EN = 0", "middle", "ar")
    return s


def sheet_div():
    s = Sheet(1000, 300, "Feedback divider: a 3-flip-flop divide-by-5 with NOR feedback at 480 MHz, then a 3-flip-flop "
                         "stage at 96 MHz whose AOI21 feedback divides by 5 when REFSEL = 00 and by 4 otherwise")
    def ff(x, y, name):
        s.box(x, y, 60, 50, name, "dffp")
        s.text(x + 5, y + 14, "D", "start", "sz"); s.text(x + 55, y + 14, "Q", "end", "sz")
        s.el.append(f'<polyline points="{x},{y + 34} {x + 7},{y + 40} {x},{y + 46}" fill="none" stroke="currentColor"/>')
        return (x, y + 10), (x + 60, y + 10), (x, y + 40)
    y = 60
    s.text(250, 24, "÷5 at 480 MHz (states 000 → 100 → 110 → 011 → 001)", "middle", "lb")
    a = ff(100, y, "XA"); b = ff(230, y, "XB"); c = ff(360, y, "XC")
    s.line(a[1], b[0], acc=True); s.line(b[1], c[0], acc=True)
    s.text(195, y + 4, "qa", "middle", "sz"); s.text(325, y + 4, "qb", "middle", "sz")
    s.dot(210, y + 10)
    s.line(c[1], (450, y + 10), (450, y + 100), (90, y + 100))
    s.dot(340, y + 10); s.line((340, y + 10), (340, y + 85), (90, y + 85))
    s.box(40, y + 75, 40, 34, "NOR", None)
    s.line((40, y + 92), (30, y + 92), (30, y + 10), (100, y + 10), acc=True)
    s.text(36, y + 4, "da", "end", "sz")
    s.line((80, y + 85), (90, y + 85)); s.line((80, y + 100), (90, y + 100))
    s.pin(20, y + 135, "ckd", "l")
    s.line((24, y + 135), (85, y + 135), (85, y + 40), (100, y + 40))
    s.line((85, y + 135), (215, y + 135), (215, y + 40), (230, y + 40))
    s.line((215, y + 135), (345, y + 135), (345, y + 40), (360, y + 40))
    s.dot(85, y + 135); s.dot(215, y + 135)
    # stage 2
    x = 560
    s.text(x + 190, 24, "÷4 / ÷5 at 96 MHz, clocked by qa", "middle", "lb")
    d = ff(x + 40, y, "XD"); e = ff(x + 170, y, "XE"); f = ff(x + 300, y, "XF")
    s.line(d[1], e[0], acc=True); s.line(e[1], f[0], acc=True)
    s.dot(x + 130, y + 10)
    s.line((x + 130, y + 10), (x + 130, y - 20), (x + 430, y - 20))
    s.pin(x + 434, y - 20, "fb → PFD", "t", acc=True)
    s.line(f[1], (x + 380, y + 10), (x + 380, y + 100), (x + 30, y + 100))
    s.dot(x + 270, y + 10); s.line((x + 270, y + 10), (x + 270, y + 85), (x + 30, y + 85))
    s.box(x - 30, y + 75, 50, 50, "AOI21", None)
    s.line((x + 20, y + 85), (x + 30, y + 85)); s.line((x + 20, y + 100), (x + 30, y + 100))
    s.line((x - 30, y + 100), (x - 40, y + 100), (x - 40, y + 10), (x + 40, y + 10), acc=True)
    s.text(x - 36, y + 4, "dd", "end", "sz")
    s.line((x + 20, y + 115), (x + 40, y + 115)); s.text(x + 44, y + 119, "sel5 (REFSEL = 00)", "start", "sz")
    s.text(x + 5, y + 150, "dd = !(qe | qf·sel5)", "middle", "sz")
    s.pin(x - 10, y + 175, "qa", "l")
    s.line((x - 6, y + 175), (x + 25, y + 175), (x + 25, y + 40), (x + 40, y + 40))
    s.line((x + 25, y + 175), (x + 155, y + 175), (x + 155, y + 40), (x + 170, y + 40))
    s.line((x + 155, y + 175), (x + 285, y + 175), (x + 285, y + 40), (x + 300, y + 40))
    s.dot(x + 25, y + 175); s.dot(x + 155, y + 175)
    s.text(500, 280, "N = 5 × 4 = 20 (REFSEL 01 / 10 / 11)   ·   N = 5 × 5 = 25 (REFSEL 00)", "middle", "lb")
    return s


def sheet_filter():
    s = Sheet(1000, 320, "Loop filter on CDR_CH_OUT_PLL with discharge switches for PLL_EN = 0, and the switched VDD/2 "
                         "reference for the VCO's fine input")
    s.pin(60, 60, "CDR_CH_OUT_PLL", "tl", acc=True)
    s.line((64, 60), (420, 60), acc=True)
    s.dot(140, 60); s.dot(260, 60)
    s.cap(140, 60, 140, "C4", "1.53 pF (MIM)")
    s.gnd(140, 140)
    s.res(260, 60, 130, "R2", "34.5 kΩ")
    s.dot(260, 140); s.text(254, 146, "nz", "end", "dev")
    s.cap(260, 140, 200, "C3", "15.1 pF (NMOS)", lab="l")
    s.gnd(260, 200)
    s.mos(405, 110, "n", "XD0", "2/0.18")
    s.line((420, 60), (420, 80)); s.line((375, 110), (365, 110)); s.text(361, 114, "enb", "end", "sz")
    s.line((420, 140), (420, 150)); s.gnd(420, 150)
    s.line((260, 140), (330, 140), (330, 210))
    s.mos(315, 240, "n", "XD1", "2/0.18")
    s.line((285, 240), (275, 240)); s.text(271, 244, "enb", "end", "sz")
    s.line((330, 270), (330, 280)); s.gnd(330, 280)
    # vref
    x = 760
    s.text(x + 30, 20, "fine reference (en = 1)", "middle", "lb")
    s.vdd(x, 40)
    s.mos(x + 15, 80, "p", "XQ0", "8/0.18", mirror=True)
    s.line((x, 40), (x, 50)); s.line((x + 45, 80), (x + 55, 80)); s.text(x + 59, 84, "enb", "start", "sz")
    s.res(x, 110, 160, "RQ0", "100 kΩ", lab="l")
    s.dot(x, 165)
    s.res(x, 165, 215, "RQ1", "100 kΩ", lab="l")
    s.mos(x + 15, 250, "n", "XQ1", "2/0.18", mirror=True)
    s.line((x + 45, 250), (x + 55, 250)); s.text(x + 59, 254, "en", "start", "sz")
    s.line((x, 280), (x, 290)); s.gnd(x, 290)
    s.line((x, 165), (x + 110, 165)); s.dot(x + 70, 165)
    s.text(x + 120, 169, "vref → XMF", "start", "pin")
    s.cap(x + 70, 165, 215, "XCQ", "0.84 pF")
    s.gnd(x + 70, 215)
    return s


SHEETS = {"top": sheet_top, "pfd": sheet_pfd, "div": sheet_div, "cp": lambda: sheet_cp(2), "filter": sheet_filter}

if __name__ == "__main__":
    for name, fn in SHEETS.items():
        sv = fn().svg()
        open(os.path.join(HERE, f"pll_{name}.svg"), "w").write(sv.replace("<defs>", STYLE + "<defs>", 1))
    print("written:", ", ".join(f"pll_{n}.svg" for n in SHEETS), "(VCO: cdr_vco.svg)")
