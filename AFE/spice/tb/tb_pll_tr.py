#!/usr/bin/env python3
"""tb_pll_tr.py - ngspice testbench of the transistor-level PLL (afe_pll_tr.sp)

Usage (from anywhere):
    python3 AFE/spice/tb/tb_pll_tr.py [case ...] [--corner tt] [--temp 27] [--vdd 1.8]

Cases (run two at a time, default all):
    vco     tuning curve of the PLL VCO: CDR_CH_OUT_PLL forced to 0 / 0.5 /
            0.7 / 0.9 / 1.0 / 1.2 V (same cell as the CDR VCO: compare with
            tb_cdr_tr.py vco)
    lock24  24 MHz, REFSEL 01 (/20): PLL_EN at 0.2 us, 8 us on, then PLL_EN = 0
    lock19  19.2 MHz, REFSEL 00 (/25), 8 us on
    ref26   26 MHz, REFSEL 10 (/20, no fractional divider), 6 us on

Checks (criteria of AFE/veriloga/tb/tb_afe_pll.va where they apply):
  - settling: every 0.25 us window of CLK_BIT_A after t_set is within
    +-800 ppm of N * f_ref; t_set - t(PLL_EN) <= 45 us (spec 4.3; reported)
  - locked frequency over the last 2 us: N * f_ref +- 200 ppm
  - control voltage CDR_CH_OUT_PLL at the end: 0.3 .. 1.5 V (inside the
    charge-pump range; the model's 0.85-0.95 V is reported, not checked)
  - lock24 only: PLL_EN = 0 -> CLK_BIT_A low without edges after 20 ns,
    REF_DIG keeps running (24 +- 1 edges per us), CDR_CH_OUT_PLL < 50 mV
    after 1 us
  - ref26: the lock detector's window count f_clk * 256 / 26 MHz must not be
    inside 4726 +- 5 (the digital must never report lock); reported: the VCO
    locks to 520 MHz if its range reaches it
Reported: lock time, static phase offset ref -> fb at the PFD, UP / DN pulse
width, CLK_BIT_A duty cycle and period spread (deterministic), REF_DIG delay,
supply current locked / off.
Prints TEST PASSED / TEST FAILED: <n> error(s).  Outputs in build/spice/.
"""
import os, re, subprocess, sys, bisect, concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tb_cdr_tr import crossings, load, tavg   # shared helpers

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SP   = os.path.join(ROOT, "AFE", "spice")
OUT  = os.path.join(ROOT, "build", "spice")
T_EN = 0.2e-6
CASES = {  # f_ref, refsel1, refsel0, N, t_on
    "lock24": (24e6, 0, 1, 20, 8e-6),
    "lock19": (19.2e6, 0, 0, 25, 8e-6),
    "ref26":  (26e6, 1, 0, 20, 6e-6),
}
OPTS = ".options method=trap trtol=7 reltol=1e-3 itl4=100 rshunt=1e12 chgtol=1e-15"

def netlist(case, corner, temp, vdd):
    fr, r1, r0, n, t_on = CASES[case]
    t_off = T_EN + t_on
    t_stop = t_off + (1.5e-6 if case == "lock24" else 0)
    per = 1 / fr
    en_pwl = f"0 0 {T_EN:.6e} 0 {T_EN + 100e-12:.6e} {vdd}"
    if case == "lock24":
        en_pwl += f" {t_off:.6e} {vdd} {t_off + 100e-12:.6e} 0"
    return t_off, t_stop, f"""* tb_pll_tr {case}
.lib "{SP}/models/generic180.lib" {corner}
.inc "{SP}/afe_pll_tr.sp"
.temp {temp}
vdd vdd 0 {vdd}
* stimulus through 500 Ohm (no ngspice stall at the source corners)
ven en_s 0 pwl({en_pwl})
ren en_s en 500
vr  fref_s 0 pulse(0 {vdd} 10n 0.2n 0.2n {per / 2 - 0.2e-9:.6e} {per:.6e})
rr  fref_s fref 500
vs1 rs1 0 {vdd * r1}
vs0 rs0 0 {vdd * r0}
x0 fref en rs1 rs0 clk refd vc vdd 0 afe_pll_tr
cl clk 0 200f
cd refd 0 50f
{OPTS}
.control
tran 20p {t_stop:.6e} 0 20p
wrdata {OUT}/tb_pll_tr_{case}.dat v(clk) v(vc) v(x0.fb) v(x0.ref_i) v(x0.up) v(x0.dn) v(refd) v(fref) i(vdd)
.endc
.end
"""

def freq(edges, a, b):
    w = [x for x in edges if a <= x < b]
    return (len(w) - 1) / (w[-1] - w[0]) if len(w) > 2 else 0.0

def run_lock(case, corner, temp, vdd):
    fr, r1, r0, n, t_on = CASES[case]
    t_off, t_stop, net = netlist(case, corner, temp, vdd)
    sp = f"{OUT}/tb_pll_tr_{case}.sp"
    open(sp, "w").write(net)
    r = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True)
    open(f"{OUT}/tb_pll_tr_{case}.log", "w").write(r.stdout + r.stderr)
    lines, err = [f"{case} ({corner}, {temp} C, {vdd} V): f_ref {fr / 1e6:g} MHz, N {n}"], 0
    dat = f"{OUT}/tb_pll_tr_{case}.dat"
    if not os.path.exists(dat):
        return 1, lines + ["  simulation failed, see the .log"]
    t, clk, vc, fb, refi, up, dn, refd, fref, ivdd = load(dat)
    if t[-1] < t_stop - 1e-9:
        return 1, lines + [f"  simulation stopped at {t[-1] * 1e6:.3f} us of {t_stop * 1e6:.3f} us  <-- incomplete"]
    th = vdd / 2
    val = lambda sig, x: sig[min(bisect.bisect_left(t, x), len(t) - 1)]
    ck = crossings(t, clk, th, True)
    target = n * fr
    # settling in 0.25 us windows
    wins, a = [], T_EN + 0.05e-6
    while a + 0.25e-6 <= t_off:
        wins.append((a, freq(ck, a, a + 0.25e-6)))
        a += 0.25e-6
    t_set = None
    for i in range(len(wins)):
        if all(abs(f / target - 1) <= 800e-6 for _, f in wins[i:]):
            t_set = wins[i][0]
            break
    f_lock = freq(ck, t_off - 2e-6, t_off)
    v_end = val(vc, t_off - 1e-9)
    if case == "ref26":
        cnt = f_lock * 256 / fr
        ok = abs(cnt - 4726) > 5
        lines.append(f"  CLK_BIT_A {f_lock / 1e6:.3f} MHz, control {v_end:.3f} V -> lock-detector window "
                     f"{cnt:.0f} (4726 +- 5 would mean lock)" + ("" if ok else "  <-- digital would lock"))
        if t_set is not None:
            lines.append(f"  the loop locks to {target / 1e6:.0f} MHz in {(t_set - T_EN) * 1e6:.2f} us "
                         "(VCO range reaches it; the digital flags refsel_err)")
        return int(not ok), lines
    if t_set is None:
        lines.append("  never settled to +-800 ppm  <-- settling"); err += 1
    else:
        lines.append(f"  settled to +-800 ppm {(t_set - T_EN) * 1e6:.2f} us after PLL_EN (limit 45 us)")
        err += (t_set - T_EN) > 45e-6
    ok = abs(f_lock / target - 1) <= 200e-6
    lines.append(f"  locked CLK_BIT_A over the last 2 us: {f_lock / 1e6:.4f} MHz ({(f_lock / target - 1) * 1e6:+.0f} ppm)"
                 + ("" if ok else "  <-- frequency"))
    err += not ok
    ok = 0.3 <= v_end <= 1.5
    lines.append(f"  CDR_CH_OUT_PLL {v_end:.3f} V (model 0.9 V; charge-pump range 0.3-1.5 V)" + ("" if ok else "  <-- range"))
    err += not ok
    # static phase offset and UP / DN pulses over the last 2 us
    rr = crossings(t, refi, th, True); fbr = crossings(t, fb, th, True)
    offs = []
    for x in [y for y in rr if t_off - 2e-6 < y < t_off]:
        j = bisect.bisect_left(fbr, x - 0.5 / fr)
        if j < len(fbr):
            offs.append(fbr[j] - x)
    def pulses(sig):
        rs, fs = crossings(t, sig, th, True), crossings(t, sig, th, False)
        w = []
        for x in [y for y in rs if t_off - 2e-6 < y < t_off]:
            j = bisect.bisect_left(fs, x)
            if j < len(fs): w.append(fs[j] - x)
        return w
    pu, pd = pulses(up), pulses(dn)
    if offs:
        lines.append(f"  PFD: fb - ref {sum(offs) / len(offs) * 1e12:+.0f} ps (static phase offset); "
                     f"UP {sum(pu) / max(len(pu), 1) * 1e12:.0f} ps, DN {sum(pd) / max(len(pd), 1) * 1e12:.0f} ps")
    # CLK_BIT_A period spread and duty
    w = [x for x in ck if t_off - 2e-6 < x < t_off]
    pers = [w[i + 1] - w[i] for i in range(len(w) - 1)]
    m = sum(pers) / len(pers)
    sd = (sum((p - m) ** 2 for p in pers) / len(pers)) ** 0.5
    fl = crossings(t, clk, th, False)
    hi = []
    for x in w[:-1]:
        j = bisect.bisect_left(fl, x)
        if j < len(fl): hi.append(fl[j] - x)
    lines.append(f"  CLK_BIT_A period {m * 1e12:.1f} ps, spread {sd * 1e12:.2f} ps rms / "
                 f"{(max(pers) - min(pers)) * 1e12:.1f} ps p-p (deterministic, no noise sources), "
                 f"duty {sum(hi) / len(hi) / m * 100:.1f} %")
    # REF_DIG delay
    fx, rx = crossings(t, fref, th, True), crossings(t, refd, th, True)
    dl = [rx[bisect.bisect_left(rx, x)] - x for x in fx[5:20] if bisect.bisect_left(rx, x) < len(rx)]
    lines.append(f"  REF_DIG delay from CDR_FREF {sum(dl) / len(dl) * 1e12:.0f} ps (model t_ref_dly 200 ps)")
    lines.append(f"  supply current locked: {tavg(t, ivdd, t_off - 2e-6, t_off) * -1e3:.2f} mA")
    if case == "lock24":
        late = [x for x in crossings(t, clk, th) if x > t_off + 20e-9]
        nref = len([x for x in rx if t_off + 0.5e-6 <= x < t_off + 1.5e-6])
        vco_off = val(vc, t_stop - 1e-9)
        ok = not late and val(clk, t_stop - 1e-9) < 0.1 and abs(nref - 24) <= 1 and vco_off < 0.05
        lines.append(f"  PLL_EN = 0: CLK_BIT_A edges {len(late)}, {val(clk, t_stop - 1e-9):.2f} V; "
                     f"REF_DIG {nref} edges/us; CDR_CH_OUT_PLL {vco_off * 1e3:.1f} mV; "
                     f"supply {tavg(t, ivdd, t_off + 0.5e-6, t_stop) * -1e6:.1f} uA" + ("" if ok else "  <-- disable"))
        err += not ok
    return err, lines

def run_vco(corner, temp, vdd):
    res = {}
    for v in (0.0, 0.5, 0.7, 0.9, 1.0, 1.2):
        sp = f"{OUT}/tb_pll_tr_vco_{v}.sp"
        open(sp, "w").write(f"""* pll vco point
.lib "{SP}/models/generic180.lib" {corner}
.inc "{SP}/afe_pll_tr.sp"
.temp {temp}
vdd vdd 0 {vdd}
ven en 0 {vdd}
vr  fref 0 0
vs1 rs1 0 0
vs0 rs0 0 {vdd}
vc  vc 0 {v}
x0 fref en rs1 rs0 clk refd vc vdd 0 afe_pll_tr
cl clk 0 200f
{OPTS}
.control
tran 5p 60n
meas tran t1 when v(clk)={vdd / 2} rise=8
meas tran t2 when v(clk)={vdd / 2} rise=18
meas tran ivdd avg i(vdd) from=20n to=60n
.endc
.end
""")
        o = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True).stdout
        g = {k: float(x) for k, x in re.findall(r"^(t1|t2|ivdd)\s*=\s*(\S+)", o, re.M)}
        res[v] = (10 / (g["t2"] - g["t1"]), -g["ivdd"])
    lines = [f"vco ({corner}, {temp} C, {vdd} V): CDR_CH_OUT_PLL forced, fine input on the VDD/2 reference"]
    for v, (f, i) in res.items():
        lines.append(f"  {v:.1f} V: {f / 1e6:6.1f} MHz, I(VDD) {i * 1e3:.2f} mA")
    k = (res[1.0][0] - res[0.5][0]) / 0.5
    lines.append(f"  K_vco (0.5-1.0 V) {k / 1e6:.0f} MHz/V (model 200)")
    e = 0
    if corner == "tt" and temp == 27 and vdd == 1.8:
        e = int(abs(res[0.9][0] / 480e6 - 1) > 0.03 or abs(k / 200e6 - 1) > 0.15)
    return e, lines

def main():
    args, opt, cases, i = sys.argv[1:], {"--corner": "tt", "--temp": "27", "--vdd": "1.8"}, [], 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = args[i + 1]; i += 2
        else:
            cases.append(args[i]); i += 1
    cases = cases or ["vco", "lock24", "lock19", "ref26"]
    corner, temp, vdd = opt["--corner"], int(opt["--temp"]), float(opt["--vdd"])
    os.makedirs(OUT, exist_ok=True)
    with cf.ThreadPoolExecutor(2) as ex:
        futs = [ex.submit(run_vco, corner, temp, vdd) if c == "vco" else ex.submit(run_lock, c, corner, temp, vdd)
                for c in cases]
        errors = 0
        for fu in futs:
            e, lines = fu.result()
            errors += e
            print("\n".join(lines), flush=True)
    print("TEST PASSED" if errors == 0 else f"TEST FAILED: {errors} error(s)")

if __name__ == "__main__":
    main()
