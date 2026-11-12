#!/usr/bin/env python3
"""tb_cdr_tr.py - ngspice testbench of the transistor-level CDR (afe_cdr_tr.sp)

Usage (from anywhere):
    python3 AFE/spice/tb/tb_cdr_tr.py [case ...] [--corner tt] [--temp 27] [--vdd 1.8]

Cases (run in parallel, default all):
    vco     tuning curves: coarse 0.5 / 0.7 / 0.9 / 1.0 V, fine 0.8 / 1.0 V
    lock0   reset, enable, 12 short packets (SYNC + PRBS7, random start
            phase) at 0 ppm, then CDR_EN = 0
    lockp   one long packet (1600 bits) at +1000 ppm
    lockn   one long packet (1600 bits) at -1000 ppm

Checks (same criteria as AFE/veriloga/tb/tb_afe_cdr.va):
  - margin of every rising sampling-clock edge (ckpd, the PD clock) from the
    nearest transition of the PD data input (din): lock time of a packet =
    bits from its first transition to the last edge with margin < 0.15 UI;
    must be <= 6 bits.  Long packets must stay locked after that.
  - HS_RXD sampled by the rising CLK_RX edges (as the digital does) equals
    the transmitted bits from the lock point on (no errors, no slip).
  - HS_RXD setup >= 0.4 ns / hold >= 0.1 ns to the rising CLK_RX edge.
  - free-running frequency with coarse = VC480 (480 MHz in tt) within 0.25 %
    of 480 MHz, before the first packet;
  - CDR_EN = 0: CLK_RX low and quiet, HS_RXD = 1, CDR_CH_OUT within 30 mV of
    0.9 V after 2 us.
Prints TEST PASSED / TEST FAILED: <n> error(s).  Outputs in build/spice/.
"""
import os, re, subprocess, sys, random, concurrent.futures as cf

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SP   = os.path.join(ROOT, "AFE", "spice")
OUT  = os.path.join(ROOT, "build", "spice")
UI   = 1 / 480e6
VC480 = 0.917          # coarse voltage for 480 MHz (tt, 27 C), what the PLL sets
M_MIN, MAX_LOCK = 0.15, 6
T_EN  = 2e-6           # CDR_EN rises (filter reset before)
T_FREE = 0.3e-6        # free-running window after enable, before data

def prbs7(n, seed=0x5A):
    s, out = seed & 0x7F, []
    for _ in range(n):
        b = ((s >> 6) ^ (s >> 5)) & 1
        s = ((s << 1) | b) & 0x7F
        out.append(b)
    return out

def packet_bits(n_pay, rng):
    """line levels (1 = J = CDR_DATA high): SYNC KJKJKJKK..., payload, EOP"""
    sync = [0, 1] * 5 + [0, 0]            # 12-bit HS SYNC as line levels (K = 0)
    pay = prbs7(n_pay, rng.randrange(1, 127))
    lvl, cur = [], sync[-1]
    for b in pay:                         # payload as NRZI levels (0 = toggle)
        cur = cur if b else 1 - cur
        lvl.append(cur)
    eop = [1 - lvl[-1]] * 8               # 8 bits at the inverted level
    return sync + lvl + eop

def build_stimulus(case, rng):
    """returns (pwl list of (t, v), list of packets (t_start, ui, bits), t_stop)"""
    ppm = {"lock0": 0, "lockp": 1000, "lockn": -1000}[case]
    ui = UI / (1 + ppm * 1e-6)
    n_pkt, n_pay = (12, 64) if case == "lock0" else (1, 1580)
    t = T_EN + T_FREE
    pwl, pkts, tr = [(0, 0.0)], [], 50e-12
    for _ in range(n_pkt):
        t += rng.uniform(0, 1) * ui       # random start phase
        bits = packet_bits(n_pay, rng)
        pkts.append((t, ui, bits))
        prev = 0
        for i, b in enumerate(bits + [0]):  # back to idle (0) after EOP
            if b != prev:
                tc = t + i * ui
                pwl += [(tc - tr / 2, 1.8 * prev), (tc + tr / 2, 1.8 * b)]
                prev = b
        t += (len(bits) + rng.randint(20, 60)) * ui
    t_dis = t + 300e-9                    # free-running window after the last packet
    return pwl, pkts, t_dis

def netlist(case, corner, temp, vdd, pwl, t_dis, t_stop):
    pwl_s = " ".join(f"{a:.6e} {v * vdd / 1.8:.4f}" for a, v in pwl)
    return f"""* tb_cdr_tr {case}
.lib "{SP}/models/generic180.lib" {corner}
.inc "{SP}/afe_cdr_tr.sp"
.temp {temp}
vdd vdd 0 {vdd}
ven en_s 0 pwl(0 0 {T_EN:.6e} 0 {T_EN + 100e-12:.6e} {vdd} {t_dis:.6e} {vdd} {t_dis + 100e-12:.6e} 0)
vc  vc 0 {VC480}
vd  data_s 0 pwl({pwl_s})
* series resistors: bounded source current at the PWL corners (ngspice
* otherwise stalls with "timestep too small" at a corner next to a clock edge)
rd  data_s data 500
ren en_s en 500
x0 data en vc clk rxd chout vdd 0 afe_cdr_tr
cl clk 0 100f
cr rxd 0 50f
.options method=trap trtol=7 reltol=1e-3 itl4=100 rshunt=1e12 chgtol=1e-15
.control
tran 10p {t_stop:.6e} 0 10p
wrdata {OUT}/tb_cdr_tr_{case}.dat v(clk) v(rxd) v(chout) v(x0.ckpd) v(x0.din) i(vdd)
.endc
.end
"""

def crossings(t, v, th, rising=None):
    out = []
    for i in range(1, len(t)):
        a, b = v[i - 1] - th, v[i] - th
        if (a < 0 <= b and rising in (None, True)) or (a >= 0 > b and rising in (None, False)):
            out.append(t[i - 1] + (t[i] - t[i - 1]) * a / (a - b))
    return out

def tavg(t, v, a, b):
    """time-weighted average of v over [a, b]"""
    acc = 0.0
    for i in range(1, len(t)):
        lo, hi = max(t[i - 1], a), min(t[i], b)
        if hi > lo:
            acc += 0.5 * (v[i - 1] + v[i]) * (hi - lo)
    return acc / (b - a)

def load(path):
    cols = None
    for line in open(path):
        f = line.split()
        if not f or not re.match(r"[-\d.]", f[0]):
            continue
        f = [float(x) for x in f]
        if cols is None:
            cols = [[] for _ in range(len(f) // 2)] + [[]]
        cols[0].append(f[0])
        for k in range(len(f) // 2):
            cols[k + 1].append(f[2 * k + 1])
    return cols  # t, clk, rxd, chout, ckpd, din, i(vdd)

def analyse(case, vdd, pkts, t_dis, t_stop, log):
    t, clk, rxd, chout, ckpd, din, ivdd = load(f"{OUT}/tb_cdr_tr_{case}.dat")
    if t[-1] < t_stop - 1e-9:
        log(f"  simulation stopped at {t[-1] * 1e6:.3f} us of {t_stop * 1e6:.3f} us (see the .log)  <-- incomplete")
        return 1, []
    th, err = vdd / 2, 0
    ck_r = crossings(t, ckpd, th, True)
    din_x = crossings(t, din, th)
    clk_r = crossings(t, clk, th, True)
    rxd_x = crossings(t, rxd, th)
    def val(sig, tt):
        import bisect
        i = min(max(bisect.bisect_left(t, tt), 1), len(t) - 1)
        return sig[i]
    # free-running frequency: after the reset (before data) and after the last packet
    t_last = pkts[-1][0] + len(pkts[-1][2]) * pkts[-1][1]
    for what, a, b in (("after reset", T_EN + 0.1e-6, T_EN + T_FREE), ("after the packets", t_last + 50e-9, t_dis)):
        fr = [x for x in clk_r if a < x < b]
        if len(fr) > 10:
            f = (len(fr) - 1) / (fr[-1] - fr[0])
            ok = abs(f / 480e6 - 1) < 0.0025
            log(f"  free-running CLK_RX {what}: {f / 1e6:.2f} MHz ({(f / 480e6 - 1) * 1e6:+.0f} ppm)" + ("" if ok else "  <-- outside 0.25 %"))
            err += not ok
    import bisect
    locks = []
    for k, (t0, ui, bits) in enumerate(pkts):
        t1 = t0 + len(bits) * ui
        edges = [x for x in ck_r if t0 < x < t1]
        bad_last = -1
        margins = []
        for x in edges:
            j = bisect.bisect_left(din_x, x)
            d = min(abs(x - din_x[j - 1]) if j > 0 else 1, abs(din_x[j] - x) if j < len(din_x) else 1)
            m = min(d / ui, 0.5)
            margins.append((x, m))
            if m < M_MIN:
                bad_last = x
        lock_bits = 0 if bad_last < 0 else int((bad_last - t0) / ui) + 1
        locks.append(lock_bits)
        after = [m for x, m in margins if x > bad_last]
        # data check: HS_RXD at rising CLK_RX vs transmitted bits, from lock on
        ce = [x for x in clk_r if t0 + (lock_bits + 3) * ui < x < t1 + 2 * ui]
        got = [1 if val(rxd, x) > th else 0 for x in ce]
        best = None
        for lat in range(0, 6):              # find the pipeline latency
            # bit index sampled at CLK_RX edge x: (x - t0)/ui - lat
            mism = 0; n = 0
            for x, g in zip(ce, got):
                i = int(round((x - t0) / ui - 0.5)) - lat
                if lock_bits + 1 <= i < len(bits):
                    n += 1; mism += (g != bits[i])
            if n and (best is None or mism < best[1]):
                best = (lat, mism, n)
        bad = best is None or best[1] > 0
        err += bad + (lock_bits > MAX_LOCK)
        log(f"  packet {k:2d}: {len(bits):4d} bits, lock {lock_bits:2d} bits, margin after lock "
            f"min {min(after) if after else 0:.2f} mean {sum(after) / max(len(after), 1):.2f} UI, "
            f"HS_RXD {best[2] - best[1] if best else 0}/{best[2] if best else 0} bits ok (latency {best[0] if best else '-'})"
            + ("  <-- lock time" if lock_bits > MAX_LOCK else "") + ("  <-- data errors" if bad else ""))
    # HS_RXD setup / hold at the rising CLK_RX edges (while enabled)
    su, ho = 9, 9
    for x in rxd_x:
        if x > t_dis or x < T_EN:
            continue
        j = bisect.bisect_left(clk_r, x)
        if j > 0: ho = min(ho, x - clk_r[j - 1])
        if j < len(clk_r): su = min(su, clk_r[j] - x)
    log(f"  HS_RXD at the CLK_RX pin: setup {su * 1e9:.3f} ns, hold {ho * 1e9:.3f} ns")
    err += (su < 0.4e-9) + (ho < 0.1e-9)
    # disable
    if case == "lock0":
        late = [x for x in crossings(t, clk, th) if x > t_dis + 20e-9]
        rx_off = min(val(rxd, x) for x in [t_dis + 20e-9, t_stop - 1e-9])
        ch = val(chout, t_stop - 1e-9)
        log(f"  supply current with CDR_EN = 0: {tavg(t, ivdd, t_dis + 1e-6, t_stop) * -1e6:.1f} uA (divider 45 uA)")
        log(f"  supply current while receiving (average): {tavg(t, ivdd, pkts[0][0], t_last) * -1e3:.2f} mA")
        ok = not late and val(clk, t_stop - 1e-9) < 0.1 and rx_off > vdd - 0.1 and abs(ch - vdd / 2) < 0.03
        log(f"  CDR_EN = 0: CLK_RX edges {len(late)}, CLK_RX {val(clk, t_stop - 1e-9):.2f} V, "
            f"HS_RXD {rx_off:.2f} V, CDR_CH_OUT {ch:.3f} V" + ("" if ok else "  <-- disable"))
        err += not ok
    return err, locks

def run_lock(case, corner, temp, vdd):
    rng = random.Random({"lock0": 3, "lockp": 5, "lockn": 7}[case])
    pwl, pkts, t_dis = build_stimulus(case, rng)
    t_stop = t_dis + (2.0e-6 if case == "lock0" else 20e-9)
    sp = f"{OUT}/tb_cdr_tr_{case}.sp"
    open(sp, "w").write(netlist(case, corner, temp, vdd, pwl, t_dis, t_stop))
    r = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True)
    open(f"{OUT}/tb_cdr_tr_{case}.log", "w").write(r.stdout + r.stderr)
    lines = []
    if not os.path.exists(f"{OUT}/tb_cdr_tr_{case}.dat"):
        return 1, [f"{case}: simulation failed, see build/spice/tb_cdr_tr_{case}.log"]
    lines.append(f"{case} ({corner}, {temp} C, {vdd} V):")
    e, locks = analyse(case, vdd, pkts, t_dis, t_stop, lines.append)
    if locks:
        lines.append(f"  lock time: mean {sum(locks) / len(locks):.1f}, worst {max(locks)} bits")
    return e, lines

def run_vco(corner, temp, vdd):
    pts = [(0.5, 0.9), (0.7, 0.9), (0.9, 0.9), (1.0, 0.9), (0.9, 0.8), (0.9, 1.0)]
    res = {}
    for vc, vf in pts:
        sp = f"{OUT}/tb_cdr_tr_vco_{vc}_{vf}.sp"
        open(sp, "w").write(f"""* vco point
.lib "{SP}/models/generic180.lib" {corner}
.inc "{SP}/afe_cdr_tr.sp"
.temp {temp}
vdd vdd 0 {vdd}
ven en 0 {vdd}
vd  data 0 0
vc  vc 0 {vc}
vf  vf 0 {vf}
x0 data en vc clk rxd vf vdd 0 afe_cdr_tr
cl clk 0 100f
.control
tran 5p 60n
meas tran t1 when v(clk)={vdd / 2} rise=8
meas tran t2 when v(clk)={vdd / 2} rise=18
meas tran th when v(clk)={vdd / 2} fall=8
meas tran ivdd avg i(vdd) from=20n to=60n
.endc
.end
""")
        o = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True).stdout
        g = {k: float(v) for k, v in re.findall(r"^(t1|t2|th|ivdd)\s*=\s*(\S+)", o, re.M)}
        res[(vc, vf)] = (10 / (g["t2"] - g["t1"]), -g["ivdd"], ((g["th"] - g["t1"]) * 10 / (g["t2"] - g["t1"])) % 1.0)
    f = lambda vc, vf: res[(vc, vf)][0]
    kc = (f(1.0, 0.9) - f(0.5, 0.9)) / 0.5
    kf = (f(0.9, 1.0) - f(0.9, 0.8)) / 0.2
    lines = [f"vco ({corner}, {temp} C, {vdd} V):"]
    for (vc, vf), (fr, i, d) in res.items():
        lines.append(f"  coarse {vc:.2f} V fine {vf:.2f} V: {fr / 1e6:6.1f} MHz, I(VDD) {i * 1e3:.2f} mA, CLK_RX duty {d * 100:.1f} %")
    lines.append(f"  K_coarse {kc / 1e6:.0f} MHz/V (model 200), K_fine {kf / 1e6:.0f} MHz/V (model 300)")
    e = 0
    if corner == "tt" and temp == 27 and vdd == 1.8:
        e += abs(kc / 200e6 - 1) > 0.15 or abs(kf / 300e6 - 1) > 0.15 or abs(f(0.9, 0.9) / 480e6 - 1) > 0.03
    e += any(abs(d - 0.5) > 0.05 for _, _, d in res.values())
    return e, lines

def main():
    args = sys.argv[1:]
    opt = {"--corner": "tt", "--temp": "27", "--vdd": "1.8"}
    cases = []
    i = 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = args[i + 1]; i += 2
        else:
            cases.append(args[i]); i += 1
    cases = cases or ["vco", "lock0", "lockp", "lockn"]
    corner, temp, vdd = opt["--corner"], int(opt["--temp"]), float(opt["--vdd"])
    os.makedirs(OUT, exist_ok=True)
    with cf.ThreadPoolExecutor(2) as ex:
        futs = [ex.submit(run_vco if c == "vco" else run_lock, *(([] if c == "vco" else [c]) + [corner, temp, vdd])) for c in cases]
        errors = 0
        for fu in futs:
            e, lines = fu.result()
            errors += e
            print("\n".join(lines), flush=True)
    print("TEST PASSED" if errors == 0 else f"TEST FAILED: {errors} error(s)")

if __name__ == "__main__":
    main()
