#!/usr/bin/env python3
"""check_ams_netlist.py - static checks of the Spectre AMS testbench tops

Run from anywhere:  python3 AFE/ams/check_ams_netlist.py [tb_ams_*.vams ...]

For each AMS top (default: every AFE/ams/tb_ams_*.vams) it checks, without a
simulator:
  * the xrun command in the header: every listed source file exists, and
    -analogcontrol / -top / -amsconnrules are given;
  * every instance in the top whose module is defined in one of those files
    (Verilog-A .va, Verilog .v, Verilog-AMS .vams): it uses named port
    connections only, names only ports the module has, connects each port at
    most once, and leaves no port unconnected;
  * every connect rule named with -amsconnrules is defined in the listed files.
Exit status 0 when everything passes.  run_ams_tests.sh runs it first.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def header_cmd(path):
    """xrun command from the header comment (lines '//   xrun ...' + continuations)."""
    lines, on = [], False
    for line in open(path):
        m = re.match(r"^//\s+(xrun\b.*)$", line) if not on else re.match(r"^//\s+(.*)$", line)
        if not on and m:
            on = True
        if on:
            if not m:
                break
            body = m.group(1).rstrip()
            lines.append(body.rstrip("\\").strip())
            if not body.endswith("\\"):
                break
    return " ".join(lines)


def module_ports(files):
    """{module: [ports]} for module / connectmodule headers in the files."""
    mods, rules = {}, set()
    for f in files:
        text = strip_comments(open(os.path.join(ROOT, f)).read())
        for m in re.finditer(r"\b(?:module|connectmodule)\s+(\w+)\s*(?:#\s*\(.*?\)\s*)?\((.*?)\)\s*;", text, re.S):
            ports = [p.strip() for p in m.group(2).split(",") if p.strip()]
            # ANSI headers: keep the last identifier of each declaration
            ports = [re.findall(r"\w+", p)[-1] for p in ports]
            mods[m.group(1)] = ports
        for m in re.finditer(r"\bconnectrules\s+(\w+)\s*;", text):
            rules.add(m.group(1))
    return mods, rules


def instances(text, mods):
    """(module, instance, connection text) for instantiations of known modules."""
    out = []
    pat = re.compile(r"\b(\w+)\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s*(\w+)\s*\(((?:[^();]|\([^()]*\))*)\)\s*;", re.S)
    for m in pat.finditer(text):
        if m.group(1) in mods:
            out.append((m.group(1), m.group(3), m.group(4)))
    return out


def check(top):
    errs = []
    cmd = header_cmd(top)
    if not cmd:
        return ["no xrun command in the header"]
    toks = cmd.split()
    srcs = [t for t in toks if re.search(r"\.(v|va|vams|sv)$", t)]
    for opt in ("-analogcontrol", "-top", "-amsconnrules"):
        if opt not in toks:
            errs.append("header command lacks " + opt)
    for f in srcs + [toks[toks.index("-analogcontrol") + 1]] if "-analogcontrol" in toks else srcs:
        if not os.path.exists(os.path.join(ROOT, f)):
            errs.append("missing file " + f)
    srcs = [f for f in srcs if os.path.exists(os.path.join(ROOT, f))]
    mods, rules = module_ports(srcs)
    if "-amsconnrules" in toks:
        r = toks[toks.index("-amsconnrules") + 1]
        if r not in rules:
            errs.append("connect rules %s not defined in the listed files" % r)
    rel = os.path.relpath(os.path.abspath(top), ROOT)
    if rel not in srcs:
        errs.append("the top itself is not in its command (%s)" % rel)
    text = strip_comments(open(top).read())
    n = 0
    for mod, inst, conn in instances(text, mods):
        n += 1
        named = re.findall(r"\.(\w+)\s*\(", conn)
        if not named:
            errs.append("%s %s: positional connections (use named ports)" % (mod, inst))
            continue
        for p in set(named):
            if named.count(p) > 1:
                errs.append("%s %s: port %s connected twice" % (mod, inst, p))
        for p in named:
            if p not in mods[mod]:
                errs.append("%s %s: no port %s" % (mod, inst, p))
        for p in mods[mod]:
            if p not in named:
                errs.append("%s %s: port %s not connected" % (mod, inst, p))
    if n == 0:
        errs.append("no instances found")
    return errs, n


def main(argv):
    tops = argv or sorted(
        os.path.join(ROOT, "AFE", "ams", f) for f in os.listdir(os.path.join(ROOT, "AFE", "ams"))
        if f.startswith("tb_ams_") and f.endswith(".vams"))
    bad = 0
    for t in tops:
        res = check(t)
        if isinstance(res, list):
            res = (res, 0)
        errs, n = res
        name = os.path.basename(t)
        if errs:
            bad += 1
            print("FAIL  %s" % name)
            for e in errs:
                print("      " + e)
        else:
            print("OK    %s  (%d instances, ports checked)" % (name, n))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
