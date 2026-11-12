# AFE transistor-level schematics (SPICE)

Transistor-level designs of the AFE blocks, as SPICE netlists that ngspice and Spectre (`simulator lang=spice`) both read. Each one has the same pins and behaviour as its idealized Verilog-A model in `AFE/veriloga/`, so it can replace the model in the Spectre testbenches.

| File | Content |
|---|---|
| `afe_cdr_tr.sp` | CDR upper loop (`afe_cdr.va`): Alexander PD, current-steering charge pump, R8 / C2 / C1 filter, V-to-I, 5-stage current-starved ring VCO, β-multiplier bias. Schematic, sizing and results: [`AFE/doc/cdr_schematic.md`](../doc/cdr_schematic.md) |
| `models/generic180.lib` | Generic 180 nm, 1.8 V BSIM3v3 models `nch` / `pch` with corners tt / ff / ss / fs / sf (placeholder, see below) |
| `tb/tb_cdr_tr.py` | ngspice testbench of `afe_cdr_tr`: VCO tuning curves, lock to packets at 0 / ±1000 ppm, retimed data, HS_RXD timing, disable |

Spectre: `AFE/veriloga/tb/tb_afe_cdr_tr.scs` runs the same netlist with the checker of `tb_afe_cdr.scs` (`run_va_tests.sh cdr_tr`).

## Running

```sh
python3 AFE/spice/tb/tb_cdr_tr.py                      # all cases, tt, 27 C, 1.8 V
python3 AFE/spice/tb/tb_cdr_tr.py vco --corner ss --temp 125 --vdd 1.62
```

Needs ngspice (`apt install ngspice`; installed here on 2026-11-12, version 42). Netlists, logs and waveforms (`wrdata` text files) go to `build/spice/`. The script prints `TEST PASSED` / `TEST FAILED: <n> error(s)` like the other testbenches. Runtime on this machine (2 cores, cases in parallel): `vco` about 5 min, `lockp` about 20 min, `lock0` and `lockn` about 60 min. All four passed on 2026-11-12 (tt, 27 °C, 1.8 V); the VCO case was also run at ss / ff, 27 °C and at ss 125 °C 1.62 V / ff −40 °C 1.98 V. Results: `AFE/doc/cdr_schematic.md` section 4.

## Models: placeholder for xh018

The X-FAB xh018 models are confidential and not in this repo (`X-FAB/` holds only the digital views so far). `generic180.lib` uses typical published 0.18 µm values, not foundry data: tox 4.1 nm, Vth ≈ +0.37 / −0.39 V, Idsat ≈ 560 / 250 µA/µm, FO4 delay ≈ 85 ps. The corners only shift Vth (±50 mV) and mobility (±8 %). Absolute numbers (VCO frequency, current, delays) will move with the real models; the topology and the loop design carry over.

To switch to xh018: replace the `.lib` line in the testbench with the X-FAB model include and its corner section, and map `nch` / `pch` to the xh018 1.8 V core device names (in `afe_cdr_tr.sp` they appear only in the two wrappers `nfet` / `pfet`, which also set the diffusion geometry). Resistors and capacitors are ideal elements with the intended device in a comment (high-ohmic poly, MIM, NMOS capacitor); replace them with the PDK devices at the same time. Then retune the VCO (`RC`, `RF`, `XMOF` multiplier) to the targets in the schematic document, and keep `X-FAB/` out of git.
