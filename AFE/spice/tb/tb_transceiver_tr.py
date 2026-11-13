#!/usr/bin/env python3
"""tb_transceiver_tr.py - ngspice testbench of the transistor-level line
transceiver (afe_transceiver_tr.sp: HS current driver, FS / LS drivers and
receivers, terminations)

Usage (from anywhere):
    python3 AFE/spice/tb/tb_transceiver_tr.py [case ...] [--corner tt] [--temp 27] [--vdd 3.3] [--vddl 1.8]

--vdd is VDD33, --vddl is VDD18.  Cases (two at a time, default all):
    seq     the sequence of AFE/veriloga/tb/tb_afe_transceiver.va (FS attach,
            HS J / K / P = N / chirp / off, FS J / K / SE0, LS J / K, device
            pulls, receiver isolation by FS_RX_EN_A and by VDD33 = 2.5 V) with
            2 pF on each wire, checked with the tolerances that
            AFE/veriloga/tb/tb_afe_transceiver_tr.scs gives the same checker
    hs      HS packet: TX_EN, 10 bits of lead (TX_LEAD default), 32-bit SYNC,
            127 bits PRBS7, 8-bit EOP into 45 Ohm at each end (2 pF per wire);
            then a device chirp K (device: pull-up on, no termination; host:
            45 Ohm)
    fs      FS packet (SYNC, 40 bits PRBS7, EOP) into 50 pF per wire, device
            pull-up and host pull-downs
    ls200, ls600
            LS packet (SYNC, 12 bits, EOP) into 200 pF / 600 pF per wire
    rx      receiver thresholds on slow ramps: single-ended (DP = DM 0 -> 3.3
            -> 0 V), differential at a common mode of 0.4 (chirp), 0.8, 1.65
            and 2.5 V; UVLO (VDD33 3.3 -> 2.6 -> 3.3 V)
    dc      operating points: terminations, pull-up, pull-downs, FS driver
            output impedance, HS current (0 / 0.4 / 0.8 V, VDD33 3.0 V, P = N),
            HS off, pok = 0, leakage and bias current with everything off

Checks: USB 2.0 figures where they exist (HS 360 .. 440 mV, 10-90 % edge
>= 500 ps; FS / LS edges 4 .. 20 / 75 .. 300 ns, rise / fall matching
90 .. 111 % / 80 .. 125 %, crossover 1.3 .. 2.0 V, VOH >= 2.8 V, VOL <= 0.3 V,
driver impedance 28 .. 44 Ohm; pull-up 1425 .. 1575 Ohm, HS termination
40.5 .. 49.5 Ohm, pull-down 14.25 .. 24.8 kOhm; receiver switching points
within the 0.8 / 2.0 V and +-100 mV (model) limits), otherwise the model's
figures with a tolerance (each check prints its limit).
Prints TEST PASSED / TEST FAILED: <n> error(s).  Outputs in build/spice/.
"""
import os, re, subprocess, sys, bisect, concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tb_cdr_tr import crossings, load, tavg   # shared helpers

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SP   = os.path.join(ROOT, "AFE", "spice")
OUT  = os.path.join(ROOT, "build", "spice")
UI   = 1 / 480e6
UI_FS, UI_LS = 1 / 12e6, 1 / 1.5e6
OPTS = ".options method=trap trtol=7 reltol=1e-3 itl4=100 rshunt=1e12 chgtol=1e-15"
INPUTS = ["txp", "txn", "txen", "oe", "dat", "se0", "ls", "rxen", "pu", "hst", "pd0", "pd1"]
IDLE = dict(txp=1, txn=0, txen=0, oe=0, dat=1, se0=0, ls=0, rxen=1, pu=0, hst=0, pd0=0, pd1=0, fet=0, fepd=1)


def prbs7(n, seed=0x5A):
    s, out = seed, []
    for _ in range(n):
        b = ((s >> 6) ^ (s >> 5)) & 1
        s = ((s << 1) | b) & 0x7F
        out.append(b)
    return out


def nrzi(bits, start):
    """line levels (1 = J) for data bits, starting after level `start`"""
    lvl, out = start, []
    for b in bits:
        lvl = lvl if b else 1 - lvl
        out.append(lvl)
    return out


class Stim:
    """0 / 1 events per input; PWL with 50 ps edges (the digital's flops)"""
    def __init__(self, **init):
        self.ev = {k: [(0.0, v)] for k, v in {**IDLE, **init}.items()}

    def set(self, t, **kw):
        for k, v in kw.items():
            self.ev[k].append((t, v))

    def pwl(self, k, hi, tr=50e-12):
        ev = sorted(self.ev[k], key=lambda e: e[0])
        cur = ev[0][1]
        pts = [(0.0, cur)]
        for t, v in ev[1:]:
            if v != cur:
                pts += [(t, cur), (t + tr, v)]
                cur = v
        return " ".join(f"{a:.7e} {b * hi:.4f}" for a, b in pts)


def netlist(name, st, t_stop, tmax, o, cl=2e-12, v33=None, extra="", saves="", control=None):
    vl = o["vddl"]
    src = "\n".join(f"v{k} {k}_s 0 pwl({st.pwl(k, vl)})\nr{k} {k}_s {k} 500" for k in INPUTS)
    src += "\n" + "\n".join(f"v{k} {k} 0 pwl({st.pwl(k, vl)})" for k in ("fet", "fepd"))
    v33 = v33 or f"0 {o['vdd']}"
    ctl = control or f"tran 10p {t_stop:.6e} 0 {tmax}\nwrdata {OUT}/tb_transceiver_tr_{name}.dat {saves}"
    return f"""* tb_transceiver_tr {name}
.lib "{SP}/models/generic180.lib" {o['corner']}
.inc "{SP}/afe_transceiver_tr.sp"
.temp {o['temp']}
v33 vdd33 0 pwl({v33})
v18 vdd18 0 {vl}
vref vref 0 1.2
{src}
x0 txp txn txen 0 vref cp cn oe dat se0 ls rxen rcv rdp rdm pu hst pd0 pd1 dp dm vdd33 vdd18 0 afe_transceiver_tr
* host: 45 Ohm terminations (fet), 15 kOhm pull-downs (fepd), switched smoothly
bfp dp 0 i = v(dp) * v(fet) / (45 * {vl})
bfm dm 0 i = v(dm) * v(fet) / (45 * {vl})
bpp dp 0 i = v(dp) * v(fepd) / (15k * {vl})
bpm dm 0 i = v(dm) * v(fepd) / (15k * {vl})
cdp dp 0 {cl}
cdm dm 0 {cl}
crcv rcv 0 20f
crdp rdp 0 20f
crdm rdm 0 20f
{extra}
{OPTS}
.control
{ctl}
.endc
.end
"""


def sim(name, net):
    sp = f"{OUT}/tb_transceiver_tr_{name}.sp"
    open(sp, "w").write(net)
    r = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True)
    log = r.stdout + r.stderr
    open(f"{OUT}/tb_transceiver_tr_{name}.log", "w").write(log)
    dat = f"{OUT}/tb_transceiver_tr_{name}.dat"
    return (load(dat) if os.path.exists(dat) else None), log


class Res:
    def __init__(self, head):
        self.lines, self.err = [head], 0

    def chk(self, ok, msg):
        self.lines.append("  " + msg + ("" if ok else "  <-- FAIL"))
        self.err += not ok

    def info(self, msg):
        self.lines.append("  " + msg)

    def out(self):
        return self.err, self.lines


def head(case, o):
    return f"{case} ({o['corner']}, {o['temp']} C, VDD33 {o['vdd']} V, VDD18 {o['vddl']} V)"


def sampler(t):
    return lambda sig, x: sig[min(bisect.bisect_left(t, x), len(t) - 1)]


# ------------------------------------------------------------------ seq
SEQ_TOL = dict(hs_amp=0.400, hs_tol=0.015, t_hsdly=0.75e-9, t_hsf=0.7e-9, t_tol=0.2e-9, v_tol=0.025,
               t_pn=3e-9, rx_lo=1.5e-9, rx_hi=3.0e-9, v_rel=0.25)


def run_seq(o):
    """the steps of tb_afe_transceiver.va; tolerances = SEQ_TOL (the .scs parameters)"""
    s = Stim()
    T, t = {}, 100e-9
    T[1] = t; s.set(t, pu=1)                                        # FS attach
    t += 100e-9; T[2] = t; s.set(t, pu=0, fepd=0, hst=1, fet=1, txp=1, txn=0, txen=1)
    t += 10e-9; T[3] = t                                            # t_en / 2
    t += 20e-9; T[4] = t; s.set(t, txp=0, txn=1)                    # K
    t += 10e-9; T[5] = t; s.set(t, txp=1)                           # P = N
    t += SEQ_TOL["t_pn"]; T[6] = t; s.set(t, txn=0, hst=0)          # chirp J
    t += 5e-9; T[7] = t; s.set(t, txen=0)
    t += 5e-9; T[8] = t; s.set(t, fet=0, fepd=1, pu=1, oe=1, dat=1, ls=0)   # FS J
    t += 100e-9; T[9] = t; s.set(t, dat=0)                          # FS K
    t += 100e-9; T[10] = t; s.set(t, se0=1)
    t += 100e-9; T[11] = t; s.set(t, se0=0, ls=1, dat=1, pu=0)      # LS J
    t += 1e-6; T[12] = t; s.set(t, dat=0)                           # LS K
    t += 1e-6; T[13] = t; s.set(t, oe=0, ls=0, dat=1, fepd=0, pu=1, pd0=1, pd1=1)
    t += 100e-9; T[14] = t; s.set(t, rxen=0)
    t += 20e-9; T[15] = t; s.set(t, rxen=1)
    t += 20e-9; T[16] = t
    v33 = f"0 {o['vdd']} {T[15]:.6e} {o['vdd']} {T[15] + 1e-9:.6e} 2.5"
    saves = "v(dp) v(dm) v(rcv) v(rdp) v(rdm) i(v33) i(v18) v(x0.xhs.rdy)"
    d, log = sim("seq", netlist("seq", s, T[16] + 1e-9, "20p", o, v33=v33, saves=saves))
    R = Res(head("seq", o) + ": the tb_afe_transceiver sequence")
    if d is None or d[0][-1] < T[16]:
        return 1, R.lines + ["  simulation failed, see the .log"]
    tt, dp, dm, rcv, rdp, rdm, i33, i18, rdy = d
    at, Q, vl = sampler(tt), SEQ_TOL, o["vddl"]
    if o["corner"] != "tt":                     # the Spectre figures are tt; corners: 0.5 .. 1.3 ns
        Q = dict(Q, t_hsdly=0.9e-9, t_hsf=0.9e-9, t_tol=0.4e-9)
    vd = [a - b for a, b in zip(dp, dm)]
    w = lambda name, v, lo, hi, f=1, u="V": R.chk(lo <= v <= hi, f"{name}: {v * f:.4g} {u} ({lo * f:.4g} .. {hi * f:.4g})")
    e = T[1] - 1e-9
    w("off: DP", at(dp, e), -0.01, 0.01); w("off: RXDP_A", at(rdp, e), -0.01, 0.1)
    R.info(f"supply current, all off: VDD33 {-tavg(tt, i33, 50e-9, e) * 1e6:.0f} uA, "
           f"VDD18 {-tavg(tt, i18, 50e-9, e) * 1e6:.1f} uA")
    e = T[2] - 1e-9
    V, vat = o["vdd"], o["vdd"] * 15 / 16.5            # levels scale with VDD33 (the checker assumes 3.3 V)
    w("attach: DP (1.5k up / 15k down)", at(dp, e), vat - 0.05, vat + 0.05); w("attach: DM", at(dm, e), -0.01, 0.01)
    w("attach: RXDP_A", at(rdp, e), vl - 0.1, vl + 0.01); w("attach: RXDM_A", at(rdm, e), -0.01, 0.1)
    w("attach: RXRCV_A", at(rcv, e), vl - 0.1, vl + 0.01)
    w("HS: |DP - DM| 10 ns after TX_EN (t_en / 2)", abs(at(vd, T[3])), 0, 0.005, 1e3, "mV")
    tr = [x for x in crossings(tt, rdy, vl / 2, True) if x > T[2]]
    R.info(f"HS ready (current handed from the dump to the line) {(tr[0] - T[2]) * 1e9:.1f} ns after TX_EN"
           if tr else "HS ready never rises")
    e = T[4] - 1e-12
    w("HS J: DP - DM", at(vd, e), Q["hs_amp"] - Q["hs_tol"], Q["hs_amp"] + Q["hs_tol"], 1e3, "mV")
    w("HS J: DM", at(dm, e), -0.005, 0.005, 1e3, "mV")
    e = T[5] - 1e-12
    w("HS K: DP - DM", at(vd, e), -Q["hs_amp"] - Q["hs_tol"], -Q["hs_amp"] + Q["hs_tol"], 1e3, "mV")
    a = [x for x in crossings(tt, vd, 0.8 * Q["hs_amp"], False) if x > T[4]]
    b = [x for x in crossings(tt, vd, -0.8 * Q["hs_amp"], False) if x > T[4]]
    c = [x for x in crossings(tt, vd, 0.0, False) if x > T[4]]
    if a and b and c:
        w("HS J->K 10-90 % fall time", b[0] - a[0], Q["t_hsf"] - Q["t_tol"], Q["t_hsf"] + Q["t_tol"], 1e9, "ns")
        w("HS TX_IN -> line delay (50 %)", c[0] - (T[4] + 25e-12), Q["t_hsdly"] - Q["t_tol"],
          Q["t_hsdly"] + Q["t_tol"], 1e9, "ns")
    else:
        R.chk(False, "HS J->K edge not found")
    e = T[6] - 1e-12
    w("HS P = N: DP - DM", at(vd, e), -Q["v_tol"], Q["v_tol"], 1e3, "mV")
    w("HS P = N: DP", at(dp, e), Q["hs_amp"] / 2 - Q["v_tol"], Q["hs_amp"] / 2 + Q["v_tol"], 1e3, "mV")
    e = T[7] - 1e-12
    w("chirp: DP into 45 Ohm", at(dp, e), 2 * Q["hs_amp"] - Q["v_tol"], 2 * Q["hs_amp"] + Q["v_tol"], 1e3, "mV")
    w("TX_EN = 0: DP", at(dp, T[8] - 1e-12), -0.005, 0.005, 1e3, "mV")
    e = T[9] - 1e-9
    w("FS J: DP", at(dp, e), V - 0.1, V + 0.01); w("FS J: DM", at(dm, e), -0.01, 0.05)
    w("FS J: RXDP_A", at(rdp, e), vl - 0.1, vl + 0.01); w("FS J: RXRCV_A", at(rcv, e), vl - 0.1, vl + 0.01)
    e = T[10] - 1e-9
    w("FS K: DM", at(dm, e), V - 0.1, V + 0.01); w("FS K: RXRCV_A", at(rcv, e), -0.01, 0.1)
    w("FS K: RXDM_A", at(rdm, e), vl - 0.1, vl + 0.01)
    a = [x for x in crossings(tt, dm, 0.1 * V, True) if x > T[9]]
    b = [x for x in crossings(tt, dm, 0.9 * V, True) if x > T[9]]
    c = [x for x in crossings(tt, vd, 0.0, False) if x > T[9]]
    r = [x for x in crossings(tt, rcv, vl / 2, False) if x > T[9]]
    if a and b and c and r:
        w("FS 10-90 % rise of DM", b[0] - a[0], 4e-9, 20e-9, 1e9, "ns")
        w("RXRCV_A delay after DP = DM", r[0] - c[0], Q["rx_lo"], Q["rx_hi"], 1e9, "ns")
    else:
        R.chk(False, "FS K edge or RXRCV_A edge not found")
    e = T[11] - 1e-9
    w("SE0: DP (pull-up against the driver)", at(dp, e), -0.01, 0.15); w("SE0: DM", at(dm, e), -0.01, 0.05)
    w("SE0: RXDP_A", at(rdp, e), -0.01, 0.1); w("SE0: RXDM_A", at(rdm, e), -0.01, 0.1)
    e = T[12] - 1e-9
    w("LS J: DM", at(dm, e), V - 0.1, V + 0.01); w("LS J: DP", at(dp, e), -0.01, 0.05)
    e = T[13] - 1e-9
    w("LS K: DP", at(dp, e), V - 0.1, V + 0.01)
    a = [x for x in crossings(tt, dp, 0.1 * V, True) if x > T[12]]
    b = [x for x in crossings(tt, dp, 0.9 * V, True) if x > T[12]]
    if a and b:
        w("LS 10-90 % rise of DP", b[0] - a[0], 75e-9, 300e-9, 1e9, "ns")
    else:
        R.chk(False, "LS K edge not found")
    e = T[14] - 1e-9
    w("device pulls: DP", at(dp, e), vat - 0.05, vat + 0.05)
    w("device pulls: DM (released 100 ns earlier)", at(dm, e), -Q["v_rel"], 0.01)
    e = T[15] - 1e-9
    w("FS_RX_EN_A = 0: RXDP_A", at(rdp, e), -0.01, 0.1); w("FS_RX_EN_A = 0: RXDM_A", at(rdm, e), -0.01, 0.1)
    w("FS_RX_EN_A = 0: RXRCV_A", at(rcv, e), vl - 0.1, vl + 0.01)
    e = T[16] - 1e-12
    w("VDD33 = 2.5 V: RXDP_A", at(rdp, e), -0.01, 0.1); w("VDD33 = 2.5 V: RXRCV_A", at(rcv, e), vl - 0.1, vl + 0.01)
    return R.out()


# ------------------------------------------------------------------ hs
def run_hs(o):
    sync = [0, 1] * 15 + [0, 0]                 # HS SYNC as line levels (K = 0)
    pay = nrzi(prbs7(127), sync[-1])
    eop = [1 - pay[-1]] * 8
    lv = sync + pay + eop
    s = Stim(hst=1, fet=1, fepd=0)
    t_en = 100e-9
    t_d = t_en + 10 * UI                        # TX_LEAD = 10: J during the lead
    s.set(t_en, txen=1)
    for i, b in enumerate(lv):
        s.set(t_d + i * UI, txp=b, txn=1 - b)
    t_end = t_d + len(lv) * UI
    s.set(t_end, txen=0, txp=1, txn=0)
    t_ch = t_end + 100e-9                       # device chirp K: pull-up on, no termination
    s.set(t_ch - 50e-9, hst=0, pu=1)
    s.set(t_ch, txen=1, txp=0, txn=1)
    t_stop = t_ch + 150e-9
    s.set(t_stop - 5e-9, txen=0, txp=1, txn=0)
    saves = "v(dp) v(dm) i(v33) i(v18) v(x0.xhs.rdy) v(x0.xhs.dq)"
    d, log = sim("hs", netlist("hs", s, t_stop, "10p", o, saves=saves))
    R = Res(head("hs", o) + ": HS packet (10 bits lead, SYNC, PRBS7, EOP) and device chirp K")
    if d is None or d[0][-1] < t_stop - 1e-9:
        return 1, R.lines + ["  simulation failed, see the .log"]
    tt, dp, dm, i33, i18, rdy, dq = d
    at, vl = sampler(tt), o["vddl"]
    vd = [a - b for a, b in zip(dp, dm)]
    # ready and settling
    tr = [x for x in crossings(tt, rdy, vl / 2, True) if x > t_en]
    if not tr:
        return R.err + 1, R.lines + ["  ready never rises  <-- FAIL"]
    t_r = tr[0]
    mx = max(abs(vd[i]) for i in range(len(tt)) if t_en < tt[i] < t_r - 0.2e-9)
    R.chk(mx < 0.005, f"no line current before ready: |DP - DM| <= {mx * 1e3:.2f} mV")
    R.chk(t_r - t_en <= 10 * UI + 0.5e-9,
          f"ready {(t_r - t_en) * 1e9:.1f} ns after TX_EN (model t_en 20 ns; must be <= the 10-bit lead "
          f"{10 * UI * 1e9:.1f} ns + 0.5 ns)")
    i_dump = at(dq, t_r - 0.3e-9) / 22.5
    # delay: zero crossings vs the TX_IN edges of the data
    edges = [t_d + i * UI for i in range(1, len(lv)) if lv[i] != lv[i - 1]]
    zc = crossings(tt, vd, 0.0)
    dl = []
    for e in edges:
        j = bisect.bisect_left(zc, e)
        if j < len(zc) and zc[j] - e < UI:
            dl.append(zc[j] - e)
    dly = sum(dl) / len(dl)
    R.chk(len(dl) == len(edges) and max(dl) - min(dl) <= 100e-12,
          f"TX_IN -> line delay {dly * 1e12:.0f} ps (model 812), crossing jitter "
          f"{(max(dl) - min(dl)) * 1e12:.1f} ps p-p over {len(dl)} edges (<= 100 ps; USB eye +-156 ps)")
    # per-bit levels
    amp_bits = [abs(at(vd, t_d + (i + 0.5) * UI + dly)) for i in range(len(lv))]
    rng = range(40, len(sync) + len(pay))
    allb = sorted(amp_bits[i] for i in rng)
    # V_HSOH / V_HSOL (USB 360 .. 440 mV) is a steady-state level: bits that end a run of three
    # equal bits; every bit centre is covered by the template 1 eye check below
    steady = sorted(amp_bits[i] for i in rng if lv[i] == lv[i - 1] == lv[i - 2])
    amp = steady[len(steady) // 2]
    R.chk(0.36 <= min(steady) and max(steady) <= 0.44,
          f"steady-state amplitude (3rd bit of a run) {min(steady) * 1e3:.1f} .. {max(steady) * 1e3:.1f} mV, "
          f"median {amp * 1e3:.1f} (USB 360 .. 440)")
    R.info(f"every bit centre: {allb[0] * 1e3:.1f} .. {allb[-1] * 1e3:.1f} mV")
    R.chk(abs(amp_bits[0] / amp - 1) <= 0.02,
          f"first SYNC bit {amp_bits[0] * 1e3:.1f} mV ({(amp_bits[0] / amp - 1) * 100:+.1f} % of steady state, "
          f"<= 2 %); dump current at ready {i_dump * 1e3:.2f} mA")
    # eye against the inner hexagon of USB 2.0 template 1 (7.1.2.2): |vd| >= 0 at 7.5 % UI rising
    # linearly to 300 mV at 37.5 %, 300 mV up to 62.5 %, back to 0 at 92.5 % (time from the mean
    # crossing); peak <= 475 mV (template outer limit 400 mV + 75 mV overshoot allowance of the
    # model's checker)
    def tmpl(x):
        return max(0.0, min(0.3, (x - 0.075) / 0.3 * 0.3, (0.925 - x) / 0.3 * 0.3))
    lo, pk, mg = 1.0, 0.0, 1.0
    for i in range(len(lv)):
        a0, a1 = t_d + i * UI + dly, t_d + (i + 1) * UI + dly
        for k in range(bisect.bisect_left(tt, a0), bisect.bisect_left(tt, a1)):
            pk = max(pk, abs(vd[k]))
            x = (tt[k] - a0) / UI
            if 0.1 <= x <= 0.9:                    # the template is 0 V at the crossings themselves
                mg = min(mg, abs(vd[k]) - tmpl(x))
            if 0.25 <= x <= 0.75:
                lo = min(lo, abs(vd[k]))
    R.chk(mg >= 0 and pk <= 0.475, f"eye: margin to the template 1 inner hexagon (300 mV at 37.5 .. 62.5 % UI) "
                                   f"{mg * 1e3:+.0f} mV (>= 0), peak {pk * 1e3:.0f} mV (<= 475)")
    R.info(f"eye: |DP - DM| >= {lo * 1e3:.0f} mV over 25 .. 75 % UI")
    ra = crossings(tt, vd, -0.8 * amp, True); rb = crossings(tt, vd, 0.8 * amp, True)
    fa = crossings(tt, vd, 0.8 * amp, False); fb = crossings(tt, vd, -0.8 * amp, False)
    rise = [y - x for x in ra if t_d < x < t_end for y in rb[bisect.bisect_left(rb, x):][:1] if y - x < UI]
    fall = [y - x for x in fa if t_d < x < t_end for y in fb[bisect.bisect_left(fb, x):][:1] if y - x < UI]
    R.chk(min(rise + fall) >= 500e-12,
          f"10-90 % edges: rise {min(rise) * 1e12:.0f} .. {max(rise) * 1e12:.0f} ps, fall {min(fall) * 1e12:.0f} .. "
          f"{max(fall) * 1e12:.0f} ps (USB >= 500 ps)")
    off = [x for x in crossings(tt, [abs(v) for v in vd], 0.005, False) if x > t_end]
    R.chk(bool(off) and off[0] - t_end < 10e-9,
          f"TX_EN falls: |DP - DM| < 5 mV {(off[0] - t_end) * 1e9:.2f} ns later" if off else "TX_EN falls: line not idle")
    R.info(f"supply current during the packet: VDD33 {-tavg(tt, i33, t_d + 20e-9, t_end - 5e-9) * 1e3:.2f} mA, "
           f"VDD18 {-tavg(tt, i18, t_d + 20e-9, t_end - 5e-9) * 1e3:.2f} mA; before TX_EN: VDD33 "
           f"{-tavg(tt, i33, 50e-9, t_en) * 1e6:.0f} uA")
    e = t_stop - 6e-9
    ck = at(dm, e) - at(dp, e)
    R.chk(0.6 <= ck <= 0.9, f"device chirp K (pull-up on, host 45 Ohm): DM - DP = {ck * 1e3:.0f} mV, "
                            f"DP {at(dp, e) * 1e3:.0f} mV (A6 model 700; USB 500 .. 900)")
    return R.out()


# ------------------------------------------------------------------ fs / ls
def run_fsls(case, o):
    ls = case != "fs"
    ui = UI_LS if ls else UI_FS
    cl = {"fs": 50e-12, "ls200": 200e-12, "ls600": 600e-12}[case]
    sync = [0, 1, 0, 1, 0, 1, 0, 0]
    pay = nrzi(prbs7(12 if ls else 40), 0)
    lv = sync + pay
    s = Stim(ls=int(ls), fepd=1, pu=int(not ls))
    t0 = 5 * ui + 200e-9                        # J driven for 4 bits before SYNC
    s.set(t0 - (4 * ui), oe=1, dat=1)           # J idle driven, then SYNC
    for i, b in enumerate(lv):
        s.set(t0 + i * ui, dat=b)
    te = t0 + len(lv) * ui
    s.set(te, se0=1); s.set(te + 2 * ui, se0=0, dat=1); s.set(te + 3 * ui, oe=0)
    t_stop = te + 4 * ui
    saves = "v(dp) v(dm) v(rcv) v(rdp) v(rdm) i(v33)"
    d, log = sim(case, netlist(case, s, t_stop, "0.5n" if ls else "0.1n", o, cl=cl, saves=saves))
    R = Res(head(case, o) + f": {'LS' if ls else 'FS'} packet into {cl * 1e12:.0f} pF")
    if d is None or d[0][-1] < t_stop - 1e-9:
        return 1, R.lines + ["  simulation failed, see the .log"]
    tt, dp, dm, rcv, rdp, rdm, i33 = d
    at, V, vl = sampler(tt), o["vdd"], o["vddl"]

    def edges(sig, rising):
        a = crossings(tt, sig, (0.1 if rising else 0.9) * V, rising)
        b = crossings(tt, sig, (0.9 if rising else 0.1) * V, rising)
        out = []
        for x in a:
            if t0 - ui < x < te:
                j = bisect.bisect_left(b, x)
                if j < len(b) and b[j] - x < ui:
                    out.append(b[j] - x)
        return out
    rs, fs_ = edges(dp, True) + edges(dm, True), edges(dp, False) + edges(dm, False)
    lim = (75e-9, 300e-9) if ls else (4e-9, 20e-9)
    R.chk(min(rs + fs_) >= lim[0] and max(rs + fs_) <= lim[1],
          f"10-90 %: rise {min(rs) * 1e9:.1f} .. {max(rs) * 1e9:.1f} ns, fall {min(fs_) * 1e9:.1f} .. "
          f"{max(fs_) * 1e9:.1f} ns ({lim[0] * 1e9:.0f} .. {lim[1] * 1e9:.0f})")
    m = (sum(rs) / len(rs)) / (sum(fs_) / len(fs_))
    ml = (0.8, 1.25) if ls else (0.9, 1.1111)
    R.chk(ml[0] <= m <= ml[1], f"rise / fall matching {m * 100:.1f} % ({ml[0] * 100:.0f} .. {ml[1] * 100:.1f})")
    vd = [a - b for a, b in zip(dp, dm)]
    zc = [x for x in crossings(tt, vd, 0.0) if t0 - ui < x < te]
    cx = [at(dp, x) for x in zc]
    R.chk(min(cx) >= 1.3 and max(cx) <= 2.0, f"crossover {min(cx):.3f} .. {max(cx):.3f} V (1.3 .. 2.0) over {len(zc)} edges")
    hi = [at(dp if b != ls else dm, t0 + (i + 0.5) * ui) for i, b in enumerate(lv)]   # J: DP high at FS,
    lo = [at(dm if b != ls else dp, t0 + (i + 0.5) * ui) for i, b in enumerate(lv)]   # DM high at LS
    R.chk(min(hi) >= 2.8 and max(lo) <= 0.3, f"levels at the bit centres: high >= {min(hi):.3f} V (VOH >= 2.8), "
                                              f"low <= {max(lo) * 1e3:.0f} mV (VOL <= 0.3 V)")
    # receivers: J = 1 means DP high at FS, DM high at LS
    bad = 0
    for i, b in enumerate(lv):
        ts = t0 + (i + 0.75) * ui
        dph = b != ls
        bad += (at(rcv, ts) > vl / 2) != dph
        bad += (at(rdp, ts) > vl / 2) != dph
        bad += (at(rdm, ts) > vl / 2) != (not dph)
    ts = te + ui
    se0 = at(rdp, ts) < 0.1 and at(rdm, ts) < 0.1
    R.chk(bad == 0 and se0, f"receivers at 3/4 of each bit: {bad} errors in {len(lv)} bits (RXRCV_A, RXDP_A, RXDM_A); "
                            f"EOP SE0: RXDP_A = RXDM_A = 0 {'yes' if se0 else 'NO'}")
    rr = crossings(tt, rcv, vl / 2)
    dly = []
    for z in zc:
        j = bisect.bisect_left(rr, z)
        if j < len(rr) and rr[j] - z < ui / 2:
            dly.append(rr[j] - z)
    pc, mc = crossings(tt, rdp, vl / 2), crossings(tt, rdm, vl / 2)
    sk = []
    for x in pc:
        if t0 < x < te:
            j = min(range(len(mc)), key=lambda k: abs(mc[k] - x))
            sk.append(abs(mc[j] - x))
    sk_lim = 100e-9 if ls else 5e-9   # FS: spec 4.4; LS: usb_line_state filters SE0 / SE1 for 14 ticks (233 ns)
    R.chk(max(dly) < (20e-9 if ls else 5e-9) and max(sk) <= sk_lim,
          f"RXRCV_A {min(dly) * 1e9:.2f} .. {max(dly) * 1e9:.2f} ns after DP = DM (model 2 ns); RXDP_A / RXDM_A "
          f"skew <= {max(sk) * 1e9:.2f} ns (limit {sk_lim * 1e9:.0f})")
    R.info(f"VDD33 current during the packet {-tavg(tt, i33, t0, te) * 1e3:.2f} mA")
    return R.out()


# ------------------------------------------------------------------ rx
def run_rx(o):
    V = o["vdd"]
    pts, segs, t = [(0.0, 0.0, 0.0)], {}, 100e-9
    def to(t1, p, m): pts.append((t1, p, m))
    to(t, 0, 0)
    segs["se_up"] = (t, t + 2e-6); to(t + 2e-6, V, V); t += 2e-6
    segs["se_dn"] = (t, t + 2e-6); to(t + 2e-6, 0, 0); t += 2e-6
    for cm in (0.4, 0.8, 1.65, 2.5):
        to(t + 50e-9, cm - 0.15, cm + 0.15); t += 100e-9; to(t, cm - 0.15, cm + 0.15)
        segs[f"up{cm}"] = (t, t + 1e-6); to(t + 1e-6, cm + 0.15, cm - 0.15); t += 1e-6
        segs[f"dn{cm}"] = (t, t + 1e-6); to(t + 1e-6, cm - 0.15, cm + 0.15); t += 1e-6
    to(t + 50e-9, 2.0, 0.0); t += 200e-9; to(t, 2.0, 0.0)          # UVLO: J at 2.0 V
    segs["uv_dn"] = (t, t + 2e-6); segs["uv_up"] = (t + 2e-6, t + 4e-6)
    v33 = f"0 {V} {t:.6e} {V} {t + 2e-6:.6e} 2.6 {t + 4e-6:.6e} {V}"
    t += 4.1e-6; to(t, 2.0, 0.0)
    pw = lambda k: " ".join(f"{a:.6e} {(p if k == 'p' else m):.4f}" for a, p, m in pts)
    extra = f"vfp fp 0 pwl({pw('p')})\nrfp fp dp 10\nvfm fm 0 pwl({pw('m')})\nrfm fm dm 10"
    s = Stim(fepd=0)
    saves = "v(dp) v(dm) v(rcv) v(rdp) v(rdm) v(vdd33) v(x0.sd33) v(x0.pok)"
    d, log = sim("rx", netlist("rx", s, t, "1n", o, cl=1e-12, v33=v33, extra=extra, saves=saves))
    R = Res(head("rx", o) + ": receiver thresholds and UVLO on slow ramps")
    if d is None or d[0][-1] < t - 1e-9:
        return 1, R.lines + ["  simulation failed, see the .log"]
    tt, dp, dm, rcv, rdp, rdm, v33n, sd33, pok = d
    at, vl = sampler(tt), o["vddl"]

    def sw(sig, rising, seg, ref, th=None):
        a, b = segs[seg]
        c = [x for x in crossings(tt, sig, th if th is not None else vl / 2, rising) if a <= x < b]
        return (at(ref, c[0]), len(c)) if c else (None, 0)
    for nm, sig in (("RXDP_A", rdp), ("RXDM_A", rdm)):
        up, nu = sw(sig, True, "se_up", dp if nm == "RXDP_A" else dm)
        dn, nd = sw(sig, False, "se_dn", dp if nm == "RXDP_A" else dm)
        ok = up is not None and dn is not None and nu == 1 and nd == 1 and 0.8 < dn < up < 2.0
        R.chk(ok, f"{nm}: high above {up:.3f} V, low below {dn:.3f} V, hysteresis {(up - dn) * 1e3:.0f} mV "
                  f"(0.8 .. 2.0 V; model 1.4 +- 0.1)" if up is not None and dn is not None else f"{nm}: no switching")
    vd = [a - b for a, b in zip(dp, dm)]
    for cm in (0.4, 0.8, 1.65, 2.5):
        up, nu = sw(rcv, True, f"up{cm}", vd)
        dn, nd = sw(rcv, False, f"dn{cm}", vd)
        ok = up is not None and dn is not None and nu == 1 and nd == 1 and -0.1 <= dn < up <= 0.1
        R.chk(ok, f"RXRCV_A at CM {cm:.2f} V: switches at {up * 1e3:+.1f} / {dn * 1e3:+.1f} mV, hysteresis "
                  f"{(up - dn) * 1e3:.1f} mV, centre {(up + dn) / 2 * 1e3:+.1f} mV (within +-100 mV; USB 200 mV "
                  f"sensitivity)" if up is not None and dn is not None else f"RXRCV_A at CM {cm}: no switching ({nu}/{nd})")
    off, n1 = sw(rdp, False, "uv_dn", v33n)
    on, n2 = sw(rdp, True, "uv_up", v33n)
    ok = off is not None and on is not None and n1 == 1 and n2 == 1 and 2.7 <= off < on <= 3.0
    R.chk(ok, f"UVLO: receivers isolated below {off:.3f} V, on again above {on:.3f} V (model 2.97; on <= 3.0, "
              f"off >= 2.7)" if off is not None and on is not None else f"UVLO: {n1} / {n2} edges")
    return R.out()


# ------------------------------------------------------------------ dc
DC_STATES = [  # (name, inputs, VDD33 or None, forced DP, forced DM)
    ("off", {}, None, 1.65, 1.65),
    ("pu0", dict(pu=1), None, 0.0, 0.0), ("pu1", dict(pu=1), None, 1.65, 0.0),
    ("hs2", dict(hst=1), None, 0.2, 0.2), ("hs4", dict(hst=1), None, 0.4, 0.4),
    ("pd", dict(pd0=1, pd1=1), None, "V", "V"),         # at VDD33: above it the pch33 drains would conduct
    ("fsj", dict(oe=1, dat=1), None, 2.8, 0.5), ("fsk", dict(oe=1, dat=0), None, 0.5, 2.8),
    ("tx0", dict(txen=1), None, 0.0, 0.0), ("tx4", dict(txen=1), None, 0.4, 0.0),
    ("tx8", dict(txen=1), None, 0.8, 0.0), ("tx30", dict(txen=1), 3.0, 0.4, 0.0),
    ("txpn", dict(txen=1, txn=1), None, 0.2, 0.2), ("txoff", dict(txen=0), None, 0.4, 0.0),
    ("txuv", dict(txen=1), 2.5, 0.4, 0.0),
]


def run_dc(o):
    vl, V = o["vddl"], o["vdd"]
    srcs = "\n".join(f"v{k} {k} 0 dc {IDLE[k] * vl}" for k in INPUTS)
    ctl = []
    for nm, inp, v33, fp, fm in DC_STATES:
        fp, fm = (V if x == "V" else x for x in (fp, fm))
        for k in INPUTS:
            ctl.append(f"alter v{k} dc = {inp.get(k, IDLE[k]) * vl}")
        ctl += [f"alter v33 dc = {v33 if v33 else V}", f"alter vfp dc = {fp}", f"alter vfm dc = {fm}", "op",
                "let ia = i(vfp)", "let ib = i(vfm)", "let ic = i(v33)", "let id = i(v18)",
                f"echo STATE {nm} $&ia $&ib $&ic $&id"]
    net = f"""* tb_transceiver_tr dc
.lib "{SP}/models/generic180.lib" {o['corner']}
.inc "{SP}/afe_transceiver_tr.sp"
.temp {o['temp']}
v33 vdd33 0 dc {V}
v18 vdd18 0 {vl}
vref vref 0 1.2
{srcs}
vfp dp 0 dc 0
vfm dm 0 dc 0
x0 txp txn txen 0 vref cp cn oe dat se0 ls rxen rcv rdp rdm pu hst pd0 pd1 dp dm vdd33 vdd18 0 afe_transceiver_tr
{OPTS}
.control
{chr(10).join(ctl)}
.endc
.end
"""
    sp = f"{OUT}/tb_transceiver_tr_dc.sp"
    open(sp, "w").write(net)
    r = subprocess.run(["ngspice", "-b", sp], capture_output=True, text=True)
    open(f"{OUT}/tb_transceiver_tr_dc.log", "w").write(r.stdout + r.stderr)
    S = {}
    for m in re.finditer(r"STATE (\w+) (\S+) (\S+) (\S+) (\S+)", r.stdout):
        S[m.group(1)] = [float(x) for x in m.group(2, 3, 4, 5)]
    R = Res(head("dc", o) + ": operating points (current into the forced DP / DM sources)")
    if len(S) != len(DC_STATES):
        return 1, R.lines + [f"  only {len(S)} of {len(DC_STATES)} operating points, see the .log"]
    F = {nm: (fp, fm) for nm, _, _, fp, fm in DC_STATES}
    # i(vfp) > 0 means current flows from the DUT into DP's source (the source sinks it)
    ip = lambda nm: S[nm][0]
    im = lambda nm: S[nm][1]
    w = lambda name, v, lo, hi, f=1, u="": R.chk(lo <= v <= hi, f"{name}: {v * f:.4g}{u} ({lo * f:.4g} .. {hi * f:.4g})")
    R.chk(abs(ip("off")) < 1e-6 and abs(im("off")) < 1e-6,
          f"all off, DP = DM = 1.65 V: leakage {ip('off') * 1e9:.1f} / {im('off') * 1e9:.1f} nA (< 1 uA)")
    R.info(f"bias current with everything off: VDD33 {-S['off'][2] * 1e6:.0f} uA, VDD18 {-S['off'][3] * 1e6:.2f} uA")
    w("pull-up, DP = 0 V", V / ip("pu0"), 1425, 1575, 1, " Ohm")
    w("pull-up, DP = 1.65 V", (V - 1.65) / ip("pu1"), 1425, 1575, 1, " Ohm")
    for nm in ("hs2", "hs4"):
        w(f"HS termination DP at {F[nm][0]} V", F[nm][0] / -ip(nm), 40.5, 49.5, 1, " Ohm")
        w(f"HS termination DM at {F[nm][1]} V", F[nm][1] / -im(nm), 40.5, 49.5, 1, " Ohm")
    w(f"pull-down DP at {V} V", V / -ip("pd"), 14.25e3, 24.8e3, 1e-3, " kOhm")
    w(f"pull-down DM at {V} V", V / -im("pd"), 14.25e3, 24.8e3, 1e-3, " kOhm")
    w("FS driver high (J, DP at 2.8 V)", (V - 2.8) / ip("fsj"), 28, 44, 1, " Ohm")
    w("FS driver low (J, DM at 0.5 V)", 0.5 / -im("fsj"), 28, 44, 1, " Ohm")
    w("FS driver high (K, DM at 2.8 V)", (V - 2.8) / im("fsk"), 28, 44, 1, " Ohm")
    w("FS driver low (K, DP at 0.5 V)", 0.5 / -ip("fsk"), 28, 44, 1, " Ohm")
    i4 = ip("tx4")
    w("HS current J into 0.4 V", i4, 17.78e-3 * 0.97, 17.78e-3 * 1.03, 1e3, " mA")
    R.chk(abs(ip("tx0") / i4 - 1) < 0.01 and abs(ip("tx8") / i4 - 1) < 0.01 and abs(ip("tx30") / i4 - 1) < 0.01,
          f"HS current at DP = 0 / 0.8 V and at VDD33 = 3.0 V: {(ip('tx0') / i4 - 1) * 100:+.2f} / "
          f"{(ip('tx8') / i4 - 1) * 100:+.2f} / {(ip('tx30') / i4 - 1) * 100:+.2f} % (within 1 %)")
    R.chk(abs(ip("txpn") / im("txpn") - 1) < 0.01 and abs((ip("txpn") + im("txpn")) / i4 - 1) < 0.02,
          f"TX_IN_P = TX_IN_N: {ip('txpn') * 1e3:.2f} / {im('txpn') * 1e3:.2f} mA into DP / DM (half each)")
    R.chk(abs(ip("txoff")) < 1e-6, f"TX_EN = 0: {ip('txoff') * 1e9:.2f} nA into DP (< 1 uA)")
    R.chk(abs(ip("txuv")) < 1e-6, f"TX_EN = 1, VDD33 = 2.5 V (UVLO): {ip('txuv') * 1e9:.2f} nA into DP (< 1 uA)")
    R.info(f"VDD33 current with TX_EN = 1: {-S['tx4'][2] * 1e3:.2f} mA (driver {i4 * 1e3:.2f} mA)")
    return R.out()


CASES = {"seq": run_seq, "hs": run_hs, "rx": run_rx, "dc": run_dc,
         "fs": lambda o: run_fsls("fs", o), "ls200": lambda o: run_fsls("ls200", o),
         "ls600": lambda o: run_fsls("ls600", o)}


def main():
    args, opt, cases, i = sys.argv[1:], {"--corner": "tt", "--temp": "27", "--vdd": "3.3", "--vddl": "1.8"}, [], 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = args[i + 1]; i += 2
        else:
            cases.append(args[i]); i += 1
    cases = cases or list(CASES)
    for c in cases:
        if c not in CASES:
            sys.exit(f"unknown case {c}; cases: {' '.join(CASES)}")
    o = dict(corner=opt["--corner"], temp=int(opt["--temp"]), vdd=float(opt["--vdd"]), vddl=float(opt["--vddl"]))
    os.makedirs(OUT, exist_ok=True)
    with cf.ThreadPoolExecutor(2) as ex:
        futs = [ex.submit(CASES[c], o) for c in cases]
        errors = 0
        for fu in futs:
            e, lines = fu.result()
            errors += e
            print("\n".join(lines), flush=True)
    print("TEST PASSED" if errors == 0 else f"TEST FAILED: {errors} error(s)")


if __name__ == "__main__":
    main()
