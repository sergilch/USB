#!/usr/bin/env python3
"""tb_receiver_tr.py - ngspice testbench of the transistor-level receiver
(afe_receiver_tr.sp: HS receiver, squelch, disconnect)

Usage (from anywhere):
    python3 AFE/spice/tb/tb_receiver_tr.py [case ...] [--corner tt] [--temp 27] [--vdd 3.3] [--vddo 1.8]

Cases (run two at a time, default all):
    seq     the sequence of AFE/veriloga/tb/tb_afe_receiver.va at 480 Mbit/s
            on a realistic HS line (current-steering driver into 45 Ohm:
            DP + DM = amplitude, so the common mode is amplitude / 2 and an
            idle line sits at 0 V), plus PRBS7 data at 400 and 150 mV
    sqamp   squelch on alternating data at 100 .. 170 mV (40 bits each): the
            dynamic threshold, which lies above the static one because the
            preamps must recover from the opposite polarity every bit
    dc0, dc2, dc5
            static thresholds at a fixed common mode of -50 / 200 / 500 mV
            (USB 2.0 HS receiver range): HS RX switching points on slow
            +-50 mV ramps, squelch comparators on 0 -> +-200 mV ramps;
            disconnect comparators on 0.4 -> 0.8 V ramps with DM (DP) at 0 V
            (the line during the HS EOP)

Checks (seq) - requirements of AFE/doc/receiver.md / DOC/afe_interface_spec.md
4.2 where they exist, otherwise the model's figures with a tolerance:
  - RX_EN = 0 for 20 ns, then on: bias settles, squelch stays asserted on the
    idle line (ready time reported)
  - 400 mV alternating: SQUELCH_A falls 3 .. 12 ns after the line becomes
    active (spec 4.2: release <= 12 ns); RX_OUT_P follows DP - DM, delay
    < 1.5 ns (all corners; nothing digital depends on it, the CDR retimes), duty 45 .. 55 %; DISC_A stays 0
  - line idle: SQUELCH_A rises 6 .. 16.7 ns later (hold 6 ns, < 8 bit times)
  - 90 mV alternating: never released; 160 mV: released
  - 2 ns burst at 400 mV: ignored
  - static 500 mV: DISC_A = 0; static 650 mV: DISC_A = 1 after 3 .. 6 ns
  - RX_EN = 0, then RX_VDD = 2.5 V: RX_OUT_P = 0, RX_OUT_N = 1,
    SQUELCH_A = 1, DISC_A = 0; RX_EN = 0: supply current < 1 uA
  - PRBS7, 127 bits at 400 mV and at 150 mV: RX_OUT_P (and RX_OUT_N) give
    every bit, sampled one delay after the bit centre; delay spread reported
Checks (sqamp): 100 mV stays squelched, 150 mV and more release (USB 2.0).
UVLO (dc2): RX_VDD ramps 3.3 -> 2.8 -> 3.3 V; the receiver must stay on down
to 3.0 V and be off at 2.9 V (model: exactly 2.97 V).
Checks (dc*): squelch 100 .. 150 mV, disconnect 525 .. 625 mV (USB 2.0),
HS RX hysteresis 10 .. 35 mV with its centre within +-5 mV (model: +-10 mV).
Prints TEST PASSED / TEST FAILED: <n> error(s).  Outputs in build/spice/.
"""
import os, re, subprocess, sys, bisect, concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tb_cdr_tr import crossings, load, tavg   # shared helpers

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SP   = os.path.join(ROOT, "AFE", "spice")
OUT  = os.path.join(ROOT, "build", "spice")
UI   = 1 / 480e6
TE   = 625e-12                 # HS edge (0 -> 100 %), as in tb_afe_receiver
OPTS = ".options method=trap trtol=7 reltol=1e-3 itl4=100 rshunt=1e12 chgtol=1e-15"


def prbs7(n, seed=0x5A):
    s, out = seed, []
    for _ in range(n):
        b = ((s >> 6) ^ (s >> 5)) & 1
        s = ((s << 1) | b) & 0x7F
        out.append(b)
    return out


class Line:
    """Piecewise-linear vd(t) and common mode; DP = cm + vd / 2, DM = cm - vd / 2."""
    def __init__(self):
        self.pts = [(0.0, 0.0, 0.0)]          # (t, vd, cm)

    def to(self, t, vd, cm):
        if t <= self.pts[-1][0]:
            t = self.pts[-1][0] + 1e-12
        self.pts.append((t, vd, cm))

    def hold(self, t):
        _, vd, cm = self.pts[-1]
        self.to(t, vd, cm)

    def bits(self, t0, bits, amp):
        """J = 1 (+amp), K = 0 (-amp); current steering: cm = amp / 2"""
        _, vd, cm = self.pts[-1]
        self.to(t0, vd, cm)
        if vd == 0.0:                          # start from idle: first level, 100 ps edge
            self.to(t0 + 100e-12, amp if bits[0] else -amp, amp / 2)
        lvl = amp if bits[0] else -amp
        for i, b in enumerate(bits[1:], 1):
            v = amp if b else -amp
            if v != lvl:
                ts = t0 + i * UI - TE / 2
                self.to(ts, lvl, amp / 2)
                self.to(ts + TE, v, amp / 2)
                lvl = v
        self.to(t0 + len(bits) * UI, lvl, amp / 2)

    def idle(self, t, tr=100e-12):
        self.hold(t)
        self.to(t + tr, 0.0, 0.0)

    def pwl(self, which):
        f = (lambda vd, cm: cm + vd / 2) if which == "p" else (lambda vd, cm: cm - vd / 2)
        return " ".join(f"{t:.6e} {f(vd, cm):.5f}" for t, vd, cm in self.pts)

    def vd(self, t):
        i = bisect.bisect_right([p[0] for p in self.pts], t)
        if i >= len(self.pts):
            return self.pts[-1][1]
        (ta, va, _), (tb, vb, _) = self.pts[i - 1], self.pts[i]
        return va + (vb - va) * (t - ta) / (tb - ta)


def alt(n):
    return [i % 2 for i in range(n)]


def netlist(name, line, en_pwl, vdd_pwl, t_stop, corner, temp, vddo, tmax, saves):
    return f"""* tb_receiver_tr {name}
.lib "{SP}/models/generic180.lib" {corner}
.inc "{SP}/afe_receiver_tr.sp"
.temp {temp}
vddo vddo 0 {vddo}
vdd_s vdd_s 0 pwl({vdd_pwl})
rvdd vdd_s vdd 1
vref vref 0 1.2
* stimulus through 500 Ohm source resistors (no ngspice stall at PWL corners)
ven en_s 0 pwl({en_pwl})
ren en_s en 500
vp p_s 0 pwl({line.pwl("p")})
rp p_s p 500
vn n_s 0 pwl({line.pwl("n")})
rn n_s n 500
* the 500 Ohm see only gate capacitance; the real line is 22.5 Ohm (45 || 45)
x0 p n en vref op on sq dc vdd 0 vddo afe_receiver_tr
cop op 0 20f
con on 0 20f
csq sq 0 20f
cdc dc 0 20f
{OPTS}
.control
tran 10p {t_stop:.6e} 0 {tmax}
wrdata {OUT}/tb_receiver_tr_{name}.dat {saves}
.endc
.end
"""


def sim(name, net):
    sp = f"{OUT}/tb_receiver_tr_{name}.sp"
    open(sp, "w").write(net)
    r = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True)
    open(f"{OUT}/tb_receiver_tr_{name}.log", "w").write(r.stdout + r.stderr)
    dat = f"{OUT}/tb_receiver_tr_{name}.dat"
    return load(dat) if os.path.exists(dat) else None


# ------------------------------------------------------------------ seq
def run_seq(corner, temp, vdd, vddo):
    L = Line()
    T = {}
    T["en"] = 20e-9
    T["a400"] = 300e-9; L.hold(T["a400"]); L.bits(T["a400"], alt(48), 0.4)       # 100 ns
    T["idle1"] = T["a400"] + 48 * UI; L.idle(T["idle1"])
    T["a90"] = 460e-9; L.bits(T["a90"], alt(48), 0.09)
    L.idle(T["a90"] + 48 * UI)
    T["a160"] = 580e-9; L.bits(T["a160"], alt(24), 0.16)
    T["idle2"] = T["a160"] + 24 * UI; L.idle(T["idle2"])
    T["burst"] = 660e-9; L.bits(T["burst"], [1], 0.4); L.idle(T["burst"] + 1.9e-9)     # 2 ns
    T["s500"] = 720e-9; L.hold(T["s500"]); L.to(T["s500"] + 100e-12, 0.5, 0.25)
    T["s650"] = 770e-9; L.hold(T["s650"]); L.to(T["s650"] + 100e-12, 0.65, 0.325)
    T["off"] = 820e-9; L.idle(T["off"] - 10e-9)
    T["lowvdd"] = 920e-9
    T["vddok"] = 980e-9
    pr = prbs7(127)
    T["p400"] = 1200e-9; L.bits(T["p400"], pr, 0.4)       # RX_EN back at 920 ns: ready by 1100 ns
    L.idle(T["p400"] + 127 * UI)
    T["p150"] = 1520e-9; L.bits(T["p150"], pr, 0.15)
    L.idle(T["p150"] + 127 * UI)
    t_stop = T["p150"] + 127 * UI + 40e-9
    v18 = vddo
    en = f"0 0 {T['en']:.4e} 0 {T['en'] + 50e-12:.4e} {v18} {T['off']:.4e} {v18} {T['off'] + 50e-12:.4e} 0 " \
         f"{T['lowvdd']:.4e} 0 {T['lowvdd'] + 50e-12:.4e} {v18}"
    vp = f"0 {vdd} {T['lowvdd']:.4e} {vdd} {T['lowvdd'] + 1e-9:.4e} 2.5 {T['vddok']:.4e} 2.5 {T['vddok'] + 1e-9:.4e} {vdd}"
    saves = "v(p) v(n) v(op) v(on) v(sq) v(dc) i(vdd_s) i(vddo) v(x0.act) v(x0.vbp18) v(x0.on)"
    net = netlist("seq", L, en, vp, t_stop, corner, temp, vddo, "20p", saves)
    d = sim("seq", net)
    head = [f"seq ({corner}, {temp} C, RX_VDD {vdd} V, RX_VDDO {vddo} V)"]
    if d is None:
        return 1, head + ["  simulation failed, see the .log"]
    t, p, n, op, on, sq, dc, ivdd, ivddo, act, vbp, ion = d
    if t[-1] < t_stop - 1e-9:
        return 1, head + [f"  simulation stopped at {t[-1] * 1e9:.1f} ns of {t_stop * 1e9:.1f} ns"]
    th = vddo / 2
    val = lambda sig, x: sig[min(bisect.bisect_left(t, x), len(t) - 1)]
    lines, err = head, 0

    def chk(ok, msg):
        nonlocal err
        lines.append("  " + msg + ("" if ok else "  <-- FAIL"))
        err += not ok

    def first(cr, a, b=1.0):
        w = [x for x in cr if a <= x < b]
        return w[0] if w else None

    sq_f, sq_r = crossings(t, sq, th, False), crossings(t, sq, th, True)
    dc_r = crossings(t, dc, th, True)
    op_r, op_f = crossings(t, op, th, True), crossings(t, op, th, False)
    vdx = [p[i] - n[i] for i in range(len(t))]
    vd_r, vd_f = crossings(t, vdx, 0.0, True), crossings(t, vdx, 0.0, False)
    # enable
    w = [x for x in t if x > T["en"]]
    vb_end = val(vbp, T["a400"] - 1e-9)
    t_rdy = next((x for x in w if abs(val(vbp, x) - vb_end) < 0.01 and
                  all(abs(val(vbp, y) - vb_end) < 0.01 for y in (x + 5e-9, x + 20e-9, x + 50e-9))), None)
    t_on = first(crossings(t, ion, th, True), T["en"], T["a400"])
    chk(not [x for x in sq_f if T["en"] < x < T["a400"]] and val(sq, T["a400"] - 1e-9) > th and t_rdy and t_on
        and t_on > t_rdy,
        f"RX_EN rises, idle line: SQUELCH_A stays 1; bias (vbp18) settled {(t_rdy - T['en']) * 1e9:.1f} ns, "
        f"outputs enabled (on) {(t_on - T['en']) * 1e9:.1f} ns after RX_EN" if t_rdy and t_on else
        "bias never settles or the receiver never turns on")
    # 400 mV
    x = first(sq_f, T["a400"], T["idle1"])
    chk(x is not None and 3e-9 <= x - T["a400"] <= 12e-9,
        f"400 mV: SQUELCH_A falls {(x - T['a400']) * 1e9:.2f} ns after the line becomes active "
        f"(spec <= 12 ns, model 4.1)" if x else "400 mV: squelch never released")
    dl, dd = [], []
    for e in [y for y in vd_r if T["a400"] + 20e-9 < y < T["idle1"] - 5e-9]:
        j = bisect.bisect_left(op_r, e)
        if j < len(op_r): dl.append(op_r[j] - e)
    for e in [y for y in vd_f if T["a400"] + 20e-9 < y < T["idle1"] - 5e-9]:
        j = bisect.bisect_left(op_f, e)
        if j < len(op_f): dd.append(op_f[j] - e)
    rise, fall = sum(dl) / len(dl), sum(dd) / len(dd)
    duty = 0.5 + (fall - rise) / (2 * UI)
    chk(max(rise, fall) < 1.5e-9 and 0.45 <= duty <= 0.55,
        f"400 mV: RX_OUT_P delay {rise * 1e12:.0f} ps rising / {fall * 1e12:.0f} ps falling after DP - DM = 0 "
        f"(model 300 ps), duty {duty * 100:.1f} %")
    chk(max(dc[i] for i in range(len(t)) if T["a400"] < t[i] < T["idle1"]) < 0.2, "400 mV alternating: DISC_A = 0")
    x = first(sq_r, T["idle1"], T["a90"])
    chk(x is not None and 6e-9 <= x - T["idle1"] <= 16.7e-9,
        f"idle: SQUELCH_A rises {(x - T['idle1']) * 1e9:.2f} ns after the last bit (6 .. 16.7 ns, model 12.1)"
        if x else "idle: squelch never asserted")
    chk(first(sq_f, T["a90"], T["a160"]) is None, "90 mV alternating: squelch not released")
    x = first(sq_f, T["a160"], T["idle2"])
    chk(x is not None, f"160 mV alternating: released after {(x - T['a160']) * 1e9:.2f} ns" if x
        else "160 mV: squelch not released")
    chk(first(sq_f, T["burst"] - 5e-9, T["s500"]) is None, "2 ns burst at 400 mV: ignored")
    chk(val(dc, T["s650"] - 1e-9) < 0.2 and first(dc_r, T["s500"], T["s650"]) is None, "static 500 mV: DISC_A = 0")
    x = first(dc_r, T["s650"], T["off"])
    chk(x is not None and 3e-9 <= x - T["s650"] <= 6e-9,
        f"static 650 mV: DISC_A rises {(x - T['s650']) * 1e9:.2f} ns later (model 4.1)" if x else
        "static 650 mV: DISC_A stays 0")
    for k, nm in ((T["off"] + 30e-9, "RX_EN = 0"), (T["vddok"] - 5e-9, "RX_VDD = 2.5 V")):
        v = [val(s, k) for s in (op, on, sq, dc)]
        chk(v[0] < 0.1 and v[1] > vddo - 0.1 and v[2] > vddo - 0.1 and v[3] < 0.1,
            f"{nm}: RX_OUT_P {v[0]:.2f}, RX_OUT_N {v[1]:.2f}, SQUELCH_A {v[2]:.2f}, DISC_A {v[3]:.2f} V")
    i_off = -tavg(t, ivdd, T["lowvdd"] - 5e-9, T["lowvdd"]) - tavg(t, ivddo, T["lowvdd"] - 5e-9, T["lowvdd"])
    chk(abs(i_off) < 1e-6, f"RX_EN = 0: supply current {i_off * 1e9:.1f} nA (95 ns after RX_EN falls)")
    lines.append(f"  supply current idle (squelched): RX_VDD {-tavg(t, ivdd, 200e-9, 290e-9) * 1e6:.0f} uA, "
                 f"RX_VDDO {-tavg(t, ivddo, 200e-9, 290e-9) * 1e6:.0f} uA; with 400 mV data: RX_VDDO "
                 f"{-tavg(t, ivddo, T['a400'] + 30e-9, T['idle1']) * 1e6:.0f} uA")
    # PRBS
    for tp, amp in ((T["p400"], 0.4), (T["p150"], 0.15)):
        es = [y for y in vd_r + vd_f if tp + 8 * UI < y < tp + 127 * UI]
        lat = []
        for e in es:
            c = op_r if e in vd_r else op_f
            j = bisect.bisect_left(c, e)
            if j < len(c): lat.append(c[j] - e)
        dly = sum(lat) / len(lat)
        bad = 0
        for i in range(8, 126):
            ts = tp + (i + 0.5) * UI + dly
            bad += (val(op, ts) > th) != bool(pr[i])
            bad += (val(on, ts) > th) == bool(pr[i])
        chk(bad == 0 and max(lat) - min(lat) < UI / 2,
            f"PRBS7 {amp * 1e3:.0f} mV: {bad} bit errors in 118 bits (RX_OUT_P and RX_OUT_N); delay "
            f"{min(lat) * 1e12:.0f} .. {max(lat) * 1e12:.0f} ps (spread {(max(lat) - min(lat)) * 1e12:.0f} ps)")
    return err, lines


# ------------------------------------------------------------------ sqamp
SQ_AMPS = (100, 110, 120, 130, 140, 145, 150, 155, 160, 170)


def run_sqamp(corner, temp, vdd, vddo):
    """alternating J/K at 480 Mbit/s, 40 bits per amplitude, 50 ns idle between"""
    L, starts = Line(), []
    t = 200e-9
    for a in SQ_AMPS:
        L.hold(t); L.bits(t, alt(40), a * 1e-3); starts.append(t)
        t += 40 * UI; L.idle(t); t += 50e-9
    net = netlist("sqamp", L, f"0 {vddo}", f"0 {vdd}", t, corner, temp, vddo, "20p", "v(sq)")
    d = sim("sqamp", net)
    head = [f"sqamp ({corner}, {temp} C, RX_VDD {vdd} V, RX_VDDO {vddo} V): squelch on 480 Mbit/s alternating data"]
    if d is None or d[0][-1] < t - 1e-9:
        return 1, head + ["  simulation failed, see the .log"]
    tt, sq = d
    fl = crossings(tt, sq, vddo / 2, False)
    rel = [any(s0 <= x < s0 + 40 * UI + 1e-9 for x in fl) for s0 in starts]
    lines = [head[0], "  " + ", ".join(f"{a} mV {'released' if r else 'squelched'}" for a, r in zip(SQ_AMPS, rel))]
    lo = next((a for a, r in zip(SQ_AMPS, rel) if r), None)
    ok = not rel[0] and all(r for a, r in zip(SQ_AMPS, rel) if a >= 150)
    lines.append(f"  dynamic threshold: released from {lo} mV (USB: 100 mV stays squelched, >= 150 mV releases)"
                 + ("" if ok else "  <-- FAIL"))
    return int(not ok), lines


# ------------------------------------------------------------------ dc
def run_dc(case, corner, temp, vdd, vddo):
    cm = {"dc0": -0.05, "dc2": 0.2, "dc5": 0.5}[case]
    L = Line()
    L.pts = [(0.0, -0.05, cm)]
    segs = []                       # (name, t0, t1)
    t = 100e-9
    L.hold(t); L.to(t + 500e-9, 0.05, cm); segs.append(("hs_up", t, t + 500e-9)); t += 500e-9
    L.to(t + 500e-9, -0.05, cm); segs.append(("hs_dn", t, t + 500e-9)); t += 500e-9
    L.to(t + 10e-9, 0.0, cm); t += 50e-9; L.hold(t)
    L.to(t + 400e-9, 0.2, cm); segs.append(("sq_p", t, t + 400e-9)); t += 400e-9
    L.to(t + 10e-9, 0.0, cm); t += 50e-9; L.hold(t)
    L.to(t + 400e-9, -0.2, cm); segs.append(("sq_n", t, t + 400e-9)); t += 400e-9
    L.to(t + 10e-9, 0.0, cm); t += 50e-9; L.hold(t)
    if case == "dc5":               # the disconnect line: one wire at 0 V, the other at vd
        L.to(t + 10e-9, 0.4, 0.2); t += 50e-9; L.hold(t)
        L.to(t + 400e-9, 0.8, 0.4); segs.append(("dc_p", t, t + 400e-9)); t += 400e-9
        L.to(t + 10e-9, -0.4, 0.2); t += 50e-9; L.hold(t)
        L.to(t + 400e-9, -0.8, 0.4); segs.append(("dc_n", t, t + 400e-9)); t += 400e-9
        L.to(t + 10e-9, 0.0, cm); t += 20e-9
    vdd_pwl = f"0 {vdd}"
    if case == "dc2":               # UVLO: RX_VDD 3.3 -> 2.8 -> 3.3 V, line idle at the common mode
        L.hold(t); segs.append(("uv_dn", t, t + 300e-9)); segs.append(("uv_up", t + 300e-9, t + 600e-9))
        vdd_pwl = f"0 {vdd} {t:.4e} {vdd} {t + 300e-9:.4e} 2.8 {t + 600e-9:.4e} {vdd}"
        t += 620e-9; L.hold(t)
    t_stop = t
    saves = "v(p) v(n) v(op) v(x0.act) v(x0.dsc) v(x0.sqp) v(x0.sqn) v(x0.dsp) v(x0.dsn) v(x0.on) v(vdd)"
    net = netlist(case, L, f"0 {vddo}", vdd_pwl, t_stop, corner, temp, vddo, "0.2n", saves)
    d = sim(case, net)
    head = [f"{case} ({corner}, {temp} C, RX_VDD {vdd} V): common mode {cm * 1e3:.0f} mV"]
    if d is None:
        return 1, head + ["  simulation failed, see the .log"]
    tt, p, n, op, act, dsc, sqp, sqn, dsp, dsn, on, vddn = d
    if tt[-1] < t_stop - 1e-9:
        return 1, head + [f"  simulation stopped at {tt[-1] * 1e9:.0f} ns"]
    th = vddo / 2
    lines, err = head, 0
    vd = lambda x: p[min(bisect.bisect_left(tt, x), len(tt) - 1)] - n[min(bisect.bisect_left(tt, x), len(tt) - 1)]

    def at(sig, rising, a, b):
        c = [x for x in crossings(tt, sig, th, rising) if a <= x < b]
        return vd(c[0]) if c else None

    S = dict((s[0], s[1:]) for s in segs)
    up, dn = at(op, True, *S["hs_up"]), at(op, False, *S["hs_dn"])
    if up is None or dn is None:
        return err + 1, lines + ["  HS RX did not switch on the +-50 mV ramps  <-- FAIL"]
    hy, ctr = up - dn, (up + dn) / 2
    ok = 10e-3 <= hy <= 35e-3 and abs(ctr) <= 5e-3
    lines.append(f"  HS RX: switches at {up * 1e3:+.1f} / {dn * 1e3:+.1f} mV: hysteresis {hy * 1e3:.1f} mV, "
                 f"centre {ctr * 1e3:+.1f} mV (model +-10 mV)" + ("" if ok else "  <-- FAIL"))
    err += not ok
    for nm, sig, seg, sg in (("squelch DP > DM", sqp, "sq_p", 1), ("squelch DM > DP", sqn, "sq_n", -1)):
        v = at(sig, True, *S[seg])
        ok = v is not None and 0.100 <= sg * v <= 0.150
        lines.append(f"  {nm}: {sg * v * 1e3:.1f} mV (100 .. 150, model 125)" if v is not None
                     else f"  {nm}: never")
        lines[-1] += "" if ok else "  <-- FAIL"
        err += not ok
    if case == "dc5":
        for nm, sig, seg, sg in (("disconnect DP > DM", dsp, "dc_p", 1), ("disconnect DM > DP", dsn, "dc_n", -1)):
            v = at(sig, True, *S[seg])
            ok = v is not None and 0.525 <= sg * v <= 0.625
            lines.append(f"  {nm} (other wire at 0 V): {sg * v * 1e3:.1f} mV (525 .. 625, model 575)"
                         if v is not None else f"  {nm}: never")
            lines[-1] += "" if ok else "  <-- FAIL"
            err += not ok
    if case == "dc2":
        c_dn = [x for x in crossings(tt, on, th, False) if S["uv_dn"][0] <= x < S["uv_dn"][1]]
        c_up = [x for x in crossings(tt, on, th, True) if S["uv_up"][0] <= x < S["uv_up"][1]]
        vat = lambda x: vddn[min(bisect.bisect_left(tt, x), len(tt) - 1)]
        if len(c_dn) == 1 and len(c_up) == 1:
            dn_v, up_v = vat(c_dn[0]), vat(c_up[0])
            ok = 2.9 <= dn_v < 3.0 and up_v < 3.0
            lines.append(f"  UVLO: off below {dn_v:.3f} V, on again above {up_v:.3f} V (model 2.97 V)"
                         + ("" if ok else "  <-- FAIL"))
            err += not ok
        else:
            lines.append(f"  UVLO: {len(c_dn)} falling / {len(c_up)} rising edges of on on the ramp  <-- FAIL")
            err += 1
    return err, lines


def main():
    args, opt, cases, i = sys.argv[1:], {"--corner": "tt", "--temp": "27", "--vdd": "3.3", "--vddo": "1.8"}, [], 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = args[i + 1]; i += 2
        else:
            cases.append(args[i]); i += 1
    cases = cases or ["seq", "sqamp", "dc0", "dc2", "dc5"]
    corner, temp, vdd, vddo = opt["--corner"], int(opt["--temp"]), float(opt["--vdd"]), float(opt["--vddo"])
    os.makedirs(OUT, exist_ok=True)
    with cf.ThreadPoolExecutor(2) as ex:
        futs = [ex.submit(run_seq, corner, temp, vdd, vddo) if c == "seq" else
                ex.submit(run_sqamp, corner, temp, vdd, vddo) if c == "sqamp" else
                ex.submit(run_dc, c, corner, temp, vdd, vddo) for c in cases]
        errors = 0
        for fu in futs:
            e, lines = fu.result()
            errors += e
            print("\n".join(lines), flush=True)
    print("TEST PASSED" if errors == 0 else f"TEST FAILED: {errors} error(s)")


if __name__ == "__main__":
    main()
