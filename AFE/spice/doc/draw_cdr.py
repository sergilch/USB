#!/usr/bin/env python3
"""draw_cdr.py - SVG schematic sheets of afe_cdr_tr.sp (AFE/spice/afe_cdr_tr.sp)

    python3 AFE/spice/doc/draw_cdr.py      -> AFE/spice/doc/cdr_*.svg

Each sheet is drawn from the netlist's instance names and sizes (W/L in um,
L = 0.18 um where not given).  Symbols: 3-terminal MOS (PMOS with a gate
bubble, source on top), zig-zag resistor, two-plate capacitor, VDD bar,
ground.  Colours: currentColor only, plus one accent (var(--accent) when the
SVG is inlined in a page, teal otherwise) for the signal path of the sheet.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ACC = "var(--accent, #0f7c80)"


class Sheet:
    def __init__(self, w, h, label):
        self.w, self.h, self.label, self.el = w, h, label, []

    # ---- primitives
    def line(self, *pts, acc=False, dash=False):
        p = " ".join(f"{x},{y}" for x, y in pts)
        st = f' stroke="{ACC}" stroke-width="2"' if acc else ""
        d = ' stroke-dasharray="4 3"' if dash else ""
        self.el.append(f'<polyline points="{p}" fill="none"{st}{d}/>')

    def dot(self, x, y):
        self.el.append(f'<circle cx="{x}" cy="{y}" r="2.6" fill="currentColor" stroke="none"/>')

    def text(self, x, y, s, anchor="start", cls="lb", size=None):
        sz = f' font-size="{size}"' if size else ""
        s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        self.el.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="{cls}"{sz}>{s}</text>')

    def pin(self, x, y, name, side="l", acc=False):
        """open circle pin with its name"""
        self.el.append(f'<circle cx="{x}" cy="{y}" r="3.5" fill="var(--bg, #fff)" '
                       f'stroke="{ACC if acc else "currentColor"}" stroke-width="1.6"/>')
        if side == "l":
            self.text(x - 8, y + 4, name, "end", "pin")
        elif side == "r":
            self.text(x + 8, y + 4, name, "start", "pin")
        elif side == "tl":
            self.text(x - 4, y - 9, name, "start", "pin")
        elif side == "t":
            self.text(x, y - 9, name, "middle", "pin")
        else:
            self.text(x, y + 17, name, "middle", "pin")

    def vdd(self, x, y, name="VDD18A"):
        self.line((x - 10, y), (x + 10, y))
        self.text(x, y - 5, name, "middle", "rail")

    def gnd(self, x, y):
        self.line((x - 10, y), (x + 10, y))
        self.line((x - 6, y + 4), (x + 6, y + 4))
        self.line((x - 2, y + 8), (x + 2, y + 8))

    def mos(self, x, y, typ, name, size, mirror=False, lab="r"):
        """MOS centred at (x, y).  Terminals: gate (x-30, y) [or (x+30, y) if
        mirror], upper (x+15, y-30) [x-15 if mirror], lower (x+15, y+30).
        NMOS: upper = drain, lower = source.  PMOS: upper = source."""
        s = -1 if mirror else 1
        cx = x
        gx = x - 6 * s
        self.line((cx, y - 15), (cx, y + 15))                           # channel
        self.line((gx, y - 12), (gx, y + 12))                           # gate plate
        if typ == "p":
            self.el.append(f'<circle cx="{x - 10 * s}" cy="{y}" r="3.5" fill="var(--bg, #fff)" stroke="currentColor"/>')
            self.line((x - 30 * s, y), (x - 13.5 * s, y))
        else:
            self.line((x - 30 * s, y), (gx, y))
        self.line((cx, y - 11), (x + 15 * s, y - 11), (x + 15 * s, y - 30))
        self.line((cx, y + 11), (x + 15 * s, y + 11), (x + 15 * s, y + 30))
        # source arrow
        if typ == "n":
            ax, ay, d = x + 9 * s, y + 11, 1
        else:
            ax, ay, d = x + 5 * s, y - 11, -1
        self.el.append(f'<polygon points="{ax},{ay - 3.5} {ax},{ay + 3.5} {ax + 6 * s * d},{ay}" '
                       f'fill="currentColor" stroke="none"/>')
        tx = x + 22 * s if lab == "r" else x - 36 * s
        anc = ("start" if s > 0 else "end") if lab == "r" else ("end" if s > 0 else "start")
        self.text(tx, y - 2, name, anc, "dev")
        self.text(tx, y + 11, size, anc, "sz")
        return dict(g=(x - 30 * s, y), u=(x + 15 * s, y - 30), d=(x + 15 * s, y + 30))

    def res(self, x, y1, y2, name, val, lab="r"):
        """vertical resistor between (x, y1) and (x, y2)"""
        m = (y1 + y2) / 2
        z = [(x, y1), (x, m - 18)]
        for i in range(6):
            z.append((x + (7 if i % 2 == 0 else -7), m - 18 + 6 * i + 3))
        z += [(x, m + 18), (x, y2)]
        self.line(*z)
        tx, anc = (x + 14, "start") if lab == "r" else (x - 14, "end")
        self.text(tx, m - 2, name, anc, "dev")
        self.text(tx, m + 11, val, anc, "sz")

    def hres(self, x1, x2, y, name, val):
        m = (x1 + x2) / 2
        z = [(x1, y), (m - 18, y)]
        for i in range(6):
            z.append((m - 18 + 6 * i + 3, y + (7 if i % 2 == 0 else -7)))
        z += [(m + 18, y), (x2, y)]
        self.line(*z)
        self.text(m, y - 12, name, "middle", "dev")
        self.text(m, y + 22, val, "middle", "sz")

    def cap(self, x, y1, y2, name, val, lab="r"):
        m = (y1 + y2) / 2
        self.line((x, y1), (x, m - 4))
        self.line((x - 12, m - 4), (x + 12, m - 4))
        self.line((x - 12, m + 4), (x + 12, m + 4))
        self.line((x, m + 4), (x, y2))
        tx, anc = (x + 18, "start") if lab == "r" else (x - 18, "end")
        self.text(tx, m - 2, name, anc, "dev")
        self.text(tx, m + 11, val, anc, "sz")

    def box(self, x, y, w, h, name, sub=None, acc=False):
        st = f'stroke="{ACC}" stroke-width="1.8"' if acc else 'stroke="currentColor"'
        self.el.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="3" fill="var(--panel, none)" {st}/>')
        self.text(x + w / 2, y + h / 2 + (0 if sub else 4), name, "middle", "bx")
        if sub:
            self.text(x + w / 2, y + h / 2 + 15, sub, "middle", "sz")

    def inv(self, x, y, name=None, size=None, w=30):
        """inverter, input (x, y), output (x + w + 8, y)"""
        h = w * 0.6
        self.el.append(f'<polygon points="{x},{y - h} {x},{y + h} {x + w},{y}" fill="var(--panel, none)" stroke="currentColor"/>')
        self.el.append(f'<circle cx="{x + w + 4}" cy="{y}" r="4" fill="var(--bg, #fff)" stroke="currentColor"/>')
        if name:
            self.text(x + w / 2 - 4, y - h - 6, name, "middle", "dev")
        if size:
            self.text(x + w / 2 - 4, y + h + 14, size, "middle", "sz")
        return (x + w + 8, y)

    def tg(self, x, y, name=None):
        """transmission gate as two opposed triangles between (x, y) and (x+30, y)"""
        self.el.append(f'<polygon points="{x},{y - 10} {x},{y + 10} {x + 30},{y}" fill="none" stroke="currentColor"/>')
        self.el.append(f'<polygon points="{x + 30},{y - 10} {x + 30},{y + 10} {x},{y}" fill="none" stroke="currentColor"/>')
        if name:
            self.text(x + 15, y - 15, name, "middle", "dev")
        return (x + 30, y)

    def arrow(self, x1, y1, x2, y2, label=None, acc=False, lx=None, ly=None, anchor="middle"):
        st = f' stroke="{ACC}" stroke-width="2"' if acc else ""
        mk = "ah2" if acc else "ah"
        self.el.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{st} marker-end="url(#{mk})"/>')
        if label:
            self.text(lx if lx is not None else (x1 + x2) / 2, ly if ly is not None else (y1 + y2) / 2 - 6, label, anchor, "ar")

    def svg(self):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-40 0 {self.w + 40} {self.h}" role="img" '
                f'aria-label="{self.label}" class="sch" fill="none" stroke="currentColor" stroke-width="1.4" '
                f'stroke-linecap="round" stroke-linejoin="round" font-family="IBM Plex Mono, ui-monospace, monospace">'
                '<defs>'
                '<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                '<path d="M0,0 L10,5 L0,10 z" fill="currentColor" stroke="none"/></marker>'
                f'<marker id="ah2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
                f'<path d="M0,0 L10,5 L0,10 z" fill="{ACC}" stroke="none"/></marker>'
                '</defs>'
                
                + "".join(self.el) + "</svg>")


STYLE = """<style>
.lb{font-size:12px;fill:currentColor} .dev{font-size:11.5px;font-weight:600;fill:currentColor}
.sz{font-size:10.5px;fill:currentColor;opacity:.72} .pin{font-size:12px;font-weight:600;fill:currentColor}
.rail{font-size:10.5px;fill:currentColor;opacity:.8} .bx{font-size:12.5px;font-weight:600;fill:currentColor}
.ar{font-size:11px;fill:currentColor;font-style:italic} text{stroke:none}
</style>"""


# =========================================================== sheets
def sheet_top():
    s = Sheet(1000, 430, "Top level: CDR_DATA to the Alexander phase detector, charge pump, R8/C2/C1 filter on CDR_CH_OUT, "
                         "V-to-I with coarse and fine inputs, 5-stage ring, INV1-INV5 buffer; INV3 clocks the phase detector, INV5 drives CLK_RX")
    s.pin(-20, 90, "CDR_DATA", "tl", acc=True)
    s.line((-16, 90), (60, 90), acc=True)
    s.box(60, 70, 70, 40, "XB0, XB1", "2 inverters")
    s.arrow(130, 90, 180, 90, "din", acc=True)
    s.box(180, 50, 160, 90, "cdr_pd", "Alexander, 4 DFF", acc=True)
    s.arrow(340, 75, 420, 75, "up / upb", acc=True)
    s.arrow(340, 110, 420, 110, "dn / dnb", acc=True)
    s.box(420, 55, 130, 75, "cdr_cp", "ICP 50 µA, steering", acc=True)
    s.line((550, 92), (660, 92), acc=True)
    s.dot(660, 92)
    s.pin(660, 40, "CDR_CH_OUT", "t")
    s.line((660, 44), (660, 92))
    # filter
    s.cap(600, 92, 150, "C1", "0.1 pF")
    s.gnd(600, 150)
    s.line((660, 92), (720, 92))
    s.res(720, 92, 140, "R8", "2 kΩ")
    s.cap(720, 140, 172, "C2", "40 pF")
    s.gnd(720, 172)
    s.text(714, 140, "nz", "end", "sz")
    s.line((660, 92), (660, 250), (600, 250), acc=True)
    s.text(645, 240, "fine", "start", "ar")
    # V2I
    s.box(440, 225, 160, 80, "vco_v2i", "MC + MF + MOFF → MPD", acc=True)
    s.pin(520, 395, "CDR_V_IN_2", "b")
    s.line((520, 391), (520, 340), (560, 340), (560, 305))
    s.text(566, 330, "coarse (from PLL)", "start", "ar")
    s.arrow(440, 250, 360, 250, "vcp", acc=True)
    s.arrow(440, 285, 360, 285, "vcn", acc=True)
    s.box(200, 225, 160, 80, "vco_ring", "5 starved stages", acc=True)
    s.line((200, 265), (150, 265), acc=True)
    s.text(155, 258, "n5", "start", "sz")
    # buffer chain below
    x, y = 60, 365
    s.line((150, 265), (150, 330), (40, 330), (40, y), (x, y), acc=True)
    o = s.inv(x, y, "INV1", None, 24)
    o = s.inv(o[0] + 10, y, "INV2", None, 24)
    s.line((o[0], y), (o[0] + 10, y))
    o = s.inv(o[0] + 10, y, "INV3", None, 24)
    ck = o[0] + 14
    s.line((o[0], y), (ck, y), acc=True)
    s.dot(ck, y)
    s.line((ck, y), (ck, 175), (260, 175), (260, 140), acc=True)
    s.text(ck + 6, 200, "ckpd", "start", "ar")
    s.line((ck, y), (ck + 20, y))
    o = s.inv(ck + 20, y, "INV4", None, 24)
    o = s.inv(o[0] + 10, y, "INV5", None, 24)
    s.line((o[0], y), (o[0] + 30, y), acc=True)
    s.pin(o[0] + 34, y, "CLK_RX", "r", acc=True)
    # HS_RXD
    s.line((300, 140), (300, 200), (820, 200))
    s.box(820, 180, 100, 40, "XO0–XO2", "qa | !en")
    s.text(560, 194, "qa", "middle", "ar")
    s.line((920, 200), (950, 200))
    s.pin(954, 200, "HS_RXD", "b")
    # enable
    s.pin(870, 260, "CDR_EN", "t")
    s.line((870, 264), (870, 290))
    s.box(830, 290, 80, 40, "XE0, XE1", "en / enb")
    s.text(870, 355, "→ bias, V-to-I, ring clamps,", "middle", "sz")
    s.text(870, 369, "UP/DN gates, HS_RXD, filter reset", "middle", "sz")
    s.box(720, 290, 90, 40, "cdr_bias", "β-mult 10 µA")
    s.text(765, 275, "vbn / vbp", "middle", "sz")
    return s


def sheet_cp(n=5):
    s = Sheet(980, 470, "Charge pump: PMOS and NMOS sources always on, switch pairs steer ICP to the filter or to vrep, "
                        "an OTA follower holds vrep at the filter voltage")
    s.vdd(150, 40); s.vdd(610, 40); s.vdd(790, 40)
    # PMOS source
    p = s.mos(135, 90, "p", "XPSRC", f"{n}×4/1")
    s.line((150, 40), (150, 60))
    s.pin(60, 90, "vbp", "l"); s.line((64, 90), (105, 90))
    s.line((150, 120), (150, 140))
    s.dot(150, 140)
    s.text(158, 136, "sp", "start", "sz")
    s.line((90, 140), (210, 140))
    # switch pair under sp
    a = s.mos(75, 185, "p", "XPSW", "4/0.18")
    b = s.mos(225, 185, "p", "XPDMP", "4/0.18", mirror=True)
    s.line((90, 140), (90, 155)); s.line((210, 140), (210, 155))
    s.pin(30, 185, "upb", "l", acc=True); s.line((34, 185), (45, 185), acc=True)
    s.pin(270, 185, "up", "r", acc=True); s.line((266, 185), (255, 185), acc=True)
    # out and vrep columns
    s.line((90, 215), (90, 240)); s.line((210, 215), (210, 240))
    s.dot(90, 240)
    s.line((90, 240), (20, 240), acc=True)
    s.pin(16, 240, "CDR_CH_OUT (out)", "tl", acc=True)
    s.dot(210, 240)
    s.line((210, 240), (330, 240))
    s.text(300, 234, "vrep", "middle", "dev")
    # NMOS switches
    c = s.mos(75, 295, "n", "XNSW", "2/0.18")
    d = s.mos(225, 295, "n", "XNDMP", "2/0.18", mirror=True)
    s.line((90, 240), (90, 265)); s.line((210, 240), (210, 265))
    s.pin(30, 295, "dn", "l", acc=True); s.line((34, 295), (45, 295), acc=True)
    s.pin(270, 295, "dnb", "r", acc=True); s.line((266, 295), (255, 295), acc=True)
    s.line((90, 325), (90, 345), (210, 345), (210, 325))
    s.dot(150, 345)
    s.text(158, 360, "sn", "start", "sz")
    s.mos(135, 390, "n", "XNSRC", f"{n}×2/1")
    s.line((150, 345), (150, 360))
    s.pin(60, 390, "vbn", "l"); s.line((64, 390), (105, 390))
    s.line((150, 420), (150, 440)); s.gnd(150, 440)
    # OTA
    s.text(700, 14, "vrep follower (OTA, 10 µA)", "middle", "lb")
    s.mos(625, 100, "p", "XO3", "4/0.5", mirror=True)
    s.mos(775, 100, "p", "XO4", "4/0.5")
    s.line((610, 40), (610, 70)); s.line((790, 40), (790, 70))
    s.line((655, 100), (745, 100)); s.line((700, 100), (700, 140), (610, 140)); s.dot(700, 100)
    s.line((610, 130), (610, 160)); s.line((790, 130), (790, 160))
    s.dot(610, 140)
    s.text(600, 150, "o1", "end", "sz")
    s.mos(595, 190, "n", "XO1", "8/0.5")
    s.mos(805, 190, "n", "XO2", "8/0.5", mirror=True)
    s.line((610, 220), (610, 240), (790, 240), (790, 220))
    s.dot(700, 240)
    s.text(708, 256, "ot", "start", "sz")
    s.mos(685, 290, "n", "XOT", "2/1")
    s.line((700, 240), (700, 260))
    s.line((655, 290), (630, 290))
    s.text(626, 294, "vbn", "end", "sz")
    s.line((700, 320), (700, 340)); s.gnd(700, 340)
    # OTA inputs
    s.line((565, 190), (520, 190))
    s.text(516, 194, "CDR_CH_OUT (+)", "end", "ar")
    s.dot(790, 160)
    s.line((790, 160), (870, 160), (870, 190), (835, 190))
    s.line((870, 160), (920, 160))
    s.dot(870, 160)
    s.text(924, 164, "vrep", "start", "dev")
    s.cap(920, 160, 230, "CVR", "1 pF")
    s.gnd(920, 230)
    s.line((330, 240), (380, 240))
    s.text(385, 244, "→ vrep (from the OTA)", "start", "ar")
    return s


def sheet_vco():
    s = Sheet(1000, 470, "VCO: coarse and fine NMOS with source resistors plus an offset current set the reference current in MPD; "
                         "MPM and MND mirror it to vcp and vcn, which starve the five ring stages")
    # V2I
    X = 70
    s.vdd(X + 120, 30); s.vdd(X + 370, 30)
    s.mos(X + 135, 80, "p", "XMPD", "2×10/0.36", mirror=True)
    s.line((X + 120, 30), (X + 120, 50))
    s.line((X + 165, 80), (X + 325, 80)); s.dot(X + 230, 80)
    s.line((X + 230, 80), (X + 230, 120), (X + 120, 120)); s.line((X + 120, 110), (X + 120, 140))
    s.dot(X + 120, 120)
    s.text(X + 230, 74, "vcp", "middle", "dev")
    s.mos(X + 355, 80, "p", "XMPM", "2×10/0.36")
    s.line((X + 370, 30), (X + 370, 50))
    s.line((X + 370, 110), (X + 370, 160)); s.dot(X + 370, 140)
    s.line((X + 370, 140), (X + 430, 140), (X + 430, 190), (X + 415, 190)); s.dot(X + 430, 140)
    s.text(X + 438, 144, "vcn", "start", "dev")
    s.mos(X + 385, 190, "n", "XMND", "2×4/0.36", mirror=True)
    s.line((X + 370, 220), (X + 370, 260)); s.gnd(X + 370, 260)
    # reference branch: MC, MF, MOFF in parallel into vcp
    s.line((X - 20, 140), (X + 240, 140)); s.dot(X + 110, 140)
    s.line((X + 110, 120), (X + 110, 140))
    s.mos(X - 35, 190, "n", "XMC", "20/0.36")
    s.line((X - 20, 140), (X - 20, 160))
    s.line((X - 65, 190), (X - 65, 166))
    s.pin(X - 65, 162, "CDR_V_IN_2", "t", acc=True)
    s.mos(X + 95, 190, "n", "XMF", "20/0.36")
    s.line((X + 110, 140), (X + 110, 160))
    s.line((X + 65, 190), (X + 65, 166))
    s.pin(X + 65, 162, "CDR_CH_OUT", "t", acc=True)
    s.mos(X + 225, 190, "n", "XMOF", "16×2/1")
    s.line((X + 240, 140), (X + 240, 160))
    s.line((X + 195, 190), (X + 195, 175)); s.text(X + 195, 168, "vbn", "middle", "sz")
    s.res(X - 20, 220, 290, "RC", "5 kΩ")
    s.res(X + 110, 220, 290, "RF", "3.2 kΩ")
    s.line((X - 20, 290), (X - 20, 310), (X + 110, 310), (X + 110, 290))
    s.dot(X + 45, 310); s.text(X + 51, 304, "ng", "start", "sz")
    s.line((X + 240, 220), (X + 240, 380)); s.gnd(X + 240, 380)
    s.mos(X + 30, 345, "n", "XSW", "40/0.18")
    s.line((X + 45, 310), (X + 45, 315))
    s.line((X, 345), (X - 10, 345)); s.text(X - 14, 349, "en", "end", "sz")
    s.line((X + 45, 375), (X + 45, 380)); s.gnd(X + 45, 380)
    s.text(X + 150, 425, "power-down (en = 0): XPD1 vcp → VDD, XPD2 vcn → VSS, XSW open", "middle", "sz")
    # stage
    x0 = 600
    s.text(x0 + 90, 14, "vco_stage (×5)", "middle", "lb")
    s.vdd(x0 + 90, 40)
    s.mos(x0 + 75, 85, "p", "XPS", "10/0.36")
    s.line((x0 + 90, 40), (x0 + 90, 55))
    s.line((x0 + 45, 85), (x0 + 25, 85)); s.text(x0 + 21, 89, "vcp", "end", "sz")
    s.mos(x0 + 75, 145, "p", "XPI", "5/0.18")
    s.line((x0 + 90, 115), (x0 + 90, 115))
    s.mos(x0 + 75, 215, "n", "XNI", "2/0.18")
    s.line((x0 + 90, 175), (x0 + 90, 185))
    s.dot(x0 + 90, 180)
    s.line((x0 + 90, 180), (x0 + 150, 180), acc=True)
    s.text(x0 + 154, 184, "out", "start", "dev")
    s.line((x0 + 45, 145), (x0 + 30, 145), (x0 + 30, 215), (x0 + 45, 215))
    s.line((x0 + 30, 180), (x0 + 5, 180), acc=True); s.dot(x0 + 30, 180)
    s.text(x0 + 1, 184, "in", "end", "dev")
    s.mos(x0 + 75, 275, "n", "XNS", "4/0.36")
    s.line((x0 + 90, 245), (x0 + 90, 245))
    s.line((x0 + 45, 275), (x0 + 25, 275)); s.text(x0 + 21, 279, "vcn", "end", "sz")
    s.line((x0 + 90, 305), (x0 + 90, 315)); s.gnd(x0 + 90, 315)
    # ring
    y = 395
    xs = [520, 600, 680, 760, 840]
    for i, x in enumerate(xs):
        s.box(x, y - 16, 50, 32, f"S{i + 1}")
        s.line((x + 50, y), (x + 80, y), acc=True)
        s.text(x + 65, y - 6, f"n{i + 1}", "middle", "sz")
    s.line((920, y), (920, y + 26), (505, y + 26), (505, y), (520, y), acc=True)
    s.dot(920, y); s.line((920, y), (950, y)); s.text(954, y + 4, "INV1", "start", "sz")
    s.text(720, y + 44, "en = 0: n1, n3, n5 → VDD, n2, n4 → VSS (XC1–XC5)", "middle", "sz")
    s.text(720, y + 58, "dummy inverters XD1–XD4 on n1–n4", "middle", "sz")
    return s


def sheet_pd():
    s = Sheet(1000, 330, "Alexander phase detector: FFA and FFB sample din on the rising and falling clock edge, FFC and FFD "
                         "delay them by one bit; UP is qc xor qd, DN is qa xor qd, both gated by en")
    def ff(x, y, name, edge):
        s.box(x, y, 80, 60, name, edge)
        s.text(x + 6, y + 16, "D", "start", "sz"); s.text(x + 74, y + 16, "Q", "end", "sz")
        s.el.append(f'<polyline points="{x},{y + 42} {x + 8},{y + 48} {x},{y + 54}" fill="none" stroke="currentColor"/>')
        return (x, y + 12), (x + 80, y + 12), (x, y + 48)
    s.pin(30, 62, "din", "t", acc=True)
    a_d, a_q, a_c = ff(120, 50, "FFA", "dffp ↑")
    b_d, b_q, b_c = ff(120, 190, "FFB", "dffn ↓")
    s.line((34, 62), (120, 62), acc=True); s.dot(70, 62)
    s.line((70, 62), (70, 202), (120, 202), acc=True)
    c_d, c_q, c_c = ff(330, 50, "FFC", "dffp ↑")
    d_d, d_q, d_c = ff(330, 190, "FFD", "dffp ↑")
    s.line(a_q, (330, 62), acc=True); s.dot(250, 62)
    s.text(240, 56, "qa = D(k)", "middle", "ar")
    s.line(b_q, (330, 202), acc=True)
    s.text(270, 196, "qb = edge", "middle", "ar")
    # clock
    s.pin(30, 300, "ckpd", "b")
    s.line((34, 300), (100, 300), (100, 98), (120, 98))
    s.line((100, 238), (120, 238)); s.dot(100, 238)
    s.line((100, 300), (310, 300), (310, 98), (330, 98)); s.dot(100, 300)
    s.line((310, 238), (330, 238)); s.dot(310, 238)
    # XORs
    def xor(x, y, name):
        s.el.append(f'<path d="M{x},{y - 20} Q{x + 18},{y} {x},{y + 20} Q{x + 40},{y + 20} {x + 55},{y} Q{x + 40},{y - 20} {x},{y - 20} Z" fill="var(--panel, none)" stroke="currentColor"/>')
        s.el.append(f'<path d="M{x - 7},{y - 20} Q{x + 11},{y} {x - 7},{y + 20}" fill="none" stroke="currentColor"/>')
        s.text(x + 26, y + 34, name, "middle", "dev")
        return (x + 2, y - 10), (x + 2, y + 10), (x + 55, y)
    u1, u2, uo = xor(560, 90, "XXU")
    d1, d2, do = xor(560, 220, "XXD")
    s.line(c_q, (520, 62), (520, 80), (u1[0] + 4, 80), acc=True)
    s.text(470, 56, "qc = D(k−1)", "middle", "ar")
    s.line(d_q, (500, 202), (500, 100), (u2[0] + 4, 100), acc=True); s.dot(500, 202)
    s.text(460, 196, "qd", "middle", "ar")
    s.line((500, 202), (500, 230), (d2[0] + 4, 230), acc=True)
    s.line((250, 62), (250, 30), (540, 30), (540, 210), (d1[0] + 4, 210), acc=True)
    # NAND + inv
    def nand(x, y, name):
        s.el.append(f'<path d="M{x},{y - 20} L{x + 25},{y - 20} A20,20 0 0 1 {x + 25},{y + 20} L{x},{y + 20} Z" fill="var(--panel, none)" stroke="currentColor"/>')
        s.el.append(f'<circle cx="{x + 49}" cy="{y}" r="4" fill="var(--bg, #fff)" stroke="currentColor"/>')
        s.text(x + 22, y + 34, name, "middle", "dev")
        return (x + 53, y)
    s.line(uo, (680, 90), acc=True); s.text(650, 84, "upx", "middle", "ar")
    nu = nand(680, 90, "XNU")
    s.line(do, (680, 220), acc=True); s.text(650, 214, "dnx", "middle", "ar")
    nd = nand(680, 220, "XND")
    s.line((660, 100), (660, 140), (640, 140)); s.text(636, 144, "en", "end", "sz")
    s.line((660, 230), (660, 270), (640, 270)); s.text(636, 274, "en", "end", "sz")
    s.line((660, 100), (680, 100)); s.line((660, 230), (680, 230))
    s.line(nu, (800, 90), acc=True); s.dot(770, 90)
    s.line((770, 90), (770, 60), (950, 60)); s.pin(954, 60, "upb", "r", acc=True)
    o = s.inv(800, 90, "XIU", None, 26); s.line(o, (950, 90), acc=True); s.pin(954, 90, "up", "r", acc=True)
    s.line(nd, (800, 220), acc=True); s.dot(770, 220)
    o = s.inv(800, 220, "XIDN", None, 26); s.line(o, (950, 220), acc=True); s.pin(954, 220, "dn", "r", acc=True)
    s.line((770, 220), (770, 250), (950, 250)); s.pin(954, 250, "dnb", "r", acc=True)
    return s


def sheet_dff():
    s = Sheet(1000, 240, "Transmission-gate master-slave flip-flop dffp: master transparent while ck is low, slave while ck is high, "
                         "weak feedback inverters and gates hold each latch; dffn swaps the latch phases")
    s.pin(30, 110, "d", "l", acc=True)
    s.line((34, 110), (70, 110), acc=True)
    t = s.tg(70, 110, "XT1"); s.text(85, 140, "on: ck = 0", "middle", "sz")
    s.line(t, (150, 110), acc=True); s.dot(150, 110); s.text(144, 100, "m", "end", "dev")
    o = s.inv(150, 110, "XI2", "0.8/2", 30)
    s.line(o, (330, 110), acc=True); s.dot(240, 110); s.text(250, 100, "mb", "middle", "dev")
    # master keeper
    s.line((240, 110), (240, 180), (230, 180))
    s.el.append('<polygon points="230,168 230,192 205,180" fill="none" stroke="currentColor"/>')
    s.el.append('<circle cx="201" cy="180" r="4" fill="var(--bg, #fff)" stroke="currentColor"/>')
    s.text(218, 205, "XI3 0.3/0.5", "middle", "sz")
    s.line((197, 180), (190, 180)); s.tg(160, 180, "XT2"); s.line((160, 180), (150, 180), (150, 110))
    s.text(175, 225, "on: ck = 1", "middle", "sz")
    t = s.tg(330, 110, "XT3"); s.text(345, 140, "on: ck = 1", "middle", "sz")
    s.line(t, (420, 110), acc=True); s.dot(420, 110); s.text(414, 100, "s", "end", "dev")
    o = s.inv(420, 110, "XI4", "1.2/3", 30)
    s.line(o, (620, 110), acc=True); s.pin(624, 110, "q", "r", acc=True); s.dot(530, 110)
    s.line((530, 110), (530, 180), (520, 180))
    s.el.append('<polygon points="520,168 520,192 495,180" fill="none" stroke="currentColor"/>')
    s.el.append('<circle cx="491" cy="180" r="4" fill="var(--bg, #fff)" stroke="currentColor"/>')
    s.text(508, 205, "XI5 0.3/0.5", "middle", "sz")
    s.line((487, 180), (480, 180)); s.tg(450, 180, "XT4"); s.line((450, 180), (420, 180), (420, 110))
    s.text(465, 225, "on: ck = 0", "middle", "sz")
    # clock buffer
    s.pin(720, 110, "ck", "l")
    o = s.inv(730, 110, "XC0", "0.8/2", 26); s.line((724, 110), (730, 110))
    s.line(o, (830, 110)); s.text(800, 100, "ckb", "middle", "dev"); s.dot(800, 110)
    o = s.inv(830, 110, "XC1", "0.8/2", 26)
    s.line(o, (920, 110)); s.text(924, 114, "cki", "start", "dev")
    s.text(850, 170, "TG: NMOS 0.5 / PMOS 1.2 µm,", "middle", "sz")
    s.text(850, 184, "keeper TG 0.3 / 0.5 µm", "middle", "sz")
    return s


def sheet_bias():
    s = Sheet(1000, 360, "Bias: constant-gm beta multiplier with RB = 10 kOhm sets I0 = 10 uA; start-up XS1/XS2/XST; "
                         "power-down switches; filter reset divider and transmission gates")
    s.vdd(110, 30); s.vdd(260, 30)
    s.mos(125, 80, "p", "XM3", "4/1", mirror=True)
    s.mos(245, 80, "p", "XM4", "4/1")
    s.line((110, 30), (110, 50)); s.line((260, 30), (260, 50))
    s.line((155, 80), (215, 80)); s.dot(185, 80)
    s.line((185, 80), (185, 130), (110, 130)); s.dot(110, 130)
    s.line((110, 110), (110, 160))
    s.text(104, 150, "vbp", "end", "dev")
    s.line((260, 110), (260, 160)); s.dot(260, 140)
    s.text(270, 144, "vbn", "start", "dev")
    s.mos(125, 190, "n", "XM2", "4×2/1", mirror=True)
    s.mos(245, 190, "n", "XM1", "2/1")
    s.line((155, 190), (215, 190)); s.dot(185, 190)
    s.line((185, 190), (185, 140), (260, 140))
    s.res(110, 220, 290, "RB", "10 kΩ", lab="l")
    s.line((110, 290), (110, 300)); s.gnd(110, 300)
    s.line((260, 220), (260, 300)); s.gnd(260, 300)
    # start-up
    s.text(450, 24, "start-up", "middle", "lb")
    s.vdd(420, 40)
    s.mos(405, 80, "p", "XS1", "0.5/8")
    s.line((420, 40), (420, 50)); s.line((375, 80), (360, 80), (360, 100)); s.gnd(360, 100)
    s.line((420, 110), (420, 160)); s.dot(420, 135)
    s.text(428, 132, "st", "start", "dev")
    s.mos(405, 190, "n", "XS2", "1/0.5")
    s.line((375, 190), (330, 190)); s.text(326, 194, "vbn", "end", "sz")
    s.line((420, 220), (420, 240)); s.gnd(420, 240)
    s.mos(525, 150, "n", "XST", "1/0.5")
    s.line((420, 135), (480, 135), (480, 150), (495, 150))
    s.line((540, 120), (540, 100)); s.text(540, 94, "vbp", "middle", "sz")
    s.line((540, 180), (540, 200)); s.text(540, 214, "vbn", "middle", "sz")
    s.text(450, 270, "power-down: XPD1 vbp → VDD,", "middle", "sz")
    s.text(450, 284, "XPD2 vbn → 0, XPD3 st → 0", "middle", "sz")
    # filter reset
    x = 740
    s.text(x + 60, 24, "filter reset (en = 0)", "middle", "lb")
    s.vdd(x, 40)
    s.mos(x + 15, 80, "p", "XR0", "8/0.18", mirror=True)
    s.line((x, 40), (x, 50)); s.line((x + 45, 80), (x + 55, 80)); s.text(x + 59, 84, "en", "start", "sz")
    s.res(x, 110, 170, "RR0", "20 kΩ", lab="l")
    s.dot(x, 175)
    s.res(x, 175, 235, "RR1", "20 kΩ", lab="l")
    s.mos(x + 15, 265, "n", "XR1", "2/0.18", mirror=True)
    s.line((x + 45, 265), (x + 55, 265)); s.text(x + 59, 269, "enb", "start", "sz")
    s.line((x, 295), (x, 305)); s.gnd(x, 305)
    s.line((x, 175), (x + 90, 175)); s.dot(x + 90, 175)
    s.text(x + 40, 168, "vmid", "middle", "dev")
    s.line((x + 90, 175), (x + 90, 130), (x + 105, 130)); t = s.tg(x + 105, 130, "XTR0"); s.line(t, (x + 150, 130))
    s.text(x + 154, 134, "CDR_CH_OUT", "start", "pin")
    s.line((x + 90, 175), (x + 90, 220), (x + 105, 220)); t = s.tg(x + 105, 220, "XTR1"); s.line(t, (x + 150, 220))
    s.text(x + 154, 224, "nz", "start", "pin")
    return s


SHEETS = {"top": sheet_top, "pd": sheet_pd, "dff": sheet_dff, "cp": sheet_cp, "vco": sheet_vco, "bias": sheet_bias}

if __name__ == "__main__":
    for name, fn in SHEETS.items():
        sv = fn().svg().replace('class="sch"', 'class="sch"', 1)
        # standalone files carry their own text style
        sv_file = sv.replace("<defs>", STYLE + "<defs>", 1)
        open(os.path.join(HERE, f"cdr_{name}.svg"), "w").write(sv_file)
    print("written:", ", ".join(f"cdr_{n}.svg" for n in SHEETS))
