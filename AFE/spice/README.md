# AFE transistor-level schematics (SPICE)

Transistor-level designs of the AFE blocks, as SPICE netlists that ngspice and Spectre (`simulator lang=spice`) both read. Each one has the same pins and behaviour as its idealized Verilog-A model in `AFE/veriloga/`, so it can replace the model in the Spectre testbenches.

| File | Content |
|---|---|
| `afe_cdr_tr.sp` | CDR upper loop (`afe_cdr.va`): Alexander PD, current-steering charge pump, R8 / C2 / C1 filter, V-to-I, 5-stage current-starved ring VCO, β-multiplier bias. Schematic, sizing and results: [`AFE/doc/cdr_schematic.md`](../doc/cdr_schematic.md) |
| `afe_pll_tr.sp` | PLL (lower loop, `afe_pll.va`): TSPC PFD, the shared charge pump (20 µA) and VCO, R2 / C3 / C4 filter, ÷20 / ÷25 divider from REFSEL, always-on REF_DIG. Schematic and results: [`AFE/doc/pll_schematic.md`](../doc/pll_schematic.md) |
| `afe_receiver_tr.sp` | HS receiver, squelch and disconnect (`afe_receiver.va`): pch33 input pairs on RX_VDD, differential-difference preamps against a resistor-string reference, comparators with hysteresis, ramp-timer squelch filter, UVLO, all thresholds from I0 = V(RX_VREF) / 60 kΩ. Schematic and results: [`AFE/doc/receiver_schematic.md`](../doc/receiver_schematic.md) |
| `afe_transceiver_tr.sp` | Line transceiver (`afe_transceiver.va`): HS current driver (17.8 mA, replica bias from TX_VREF, dump + ready timer, turn-on kick cancellation, parked switches), FS / LS push-pull drivers with Miller slew control, Schmitt and rail-to-rail receivers, pull-up / 45 Ω / pull-down terminations, UVLO; VDD33 thick oxide on the line, VDD18 logic. Schematic and results: [`AFE/doc/transceiver_schematic.md`](../doc/transceiver_schematic.md) |
| `afe_cells.sp` | Cells shared by all netlists: logic, flip-flops, bias, charge pump (`n` × 10 µA), **the VCO** (the CDR's VCO must equal the PLL's). Change it once, rerun both testbenches |
| `models/generic180.lib` | Generic 180 nm BSIM3v3 models `nch` / `pch` (1.8 V) and `nch33` / `pch33` (3.3 V thick oxide) with corners tt / ff / ss / fs / sf (placeholder, see below) |
| `tb/tb_pll_tr.py` | ngspice testbench of `afe_pll_tr`: VCO curve, 24 MHz / 19.2 MHz lock and settling, 26 MHz with ÷20, PLL_EN = 0, PFD offset, period spread, REF_DIG |
| `tb/tb_receiver_tr.py` | ngspice testbench of `afe_receiver_tr`: the `tb_afe_receiver` sequence on a realistic HS line, PRBS7 at 400 / 150 mV, squelch on alternating data 100–170 mV, static thresholds at −50 / 200 / 500 mV common mode, UVLO |
| `tb/tb_transceiver_tr.py` | ngspice testbench of `afe_transceiver_tr`: the `tb_afe_transceiver` sequence (`seq`), HS packet with eye / jitter / edges / ready time (`hs`), FS at 50 pF and LS at 200 / 600 pF with edge matching, crossover and receiver errors (`fs`, `ls200`, `ls600`), receiver thresholds and UVLO (`rx`), DC currents and resistances (`dc`) |
| `doc/draw_cdr.py`, `doc/draw_pll.py`, `doc/draw_receiver.py`, `doc/draw_transceiver.py` | Generate the SVG schematic sheets `doc/cdr_*.svg`, `doc/pll_*.svg`, `doc/rx_*.svg`, `doc/xc_*.svg` from the instance names and sizes; rerun after a netlist change |
| `tb/tb_cdr_tr.py` | ngspice testbench of `afe_cdr_tr`: VCO tuning curves, lock to packets at 0 / ±1000 ppm, retimed data, HS_RXD timing, disable |

Spectre: `AFE/veriloga/tb/tb_afe_cdr_tr.scs`, `tb_afe_pll_tr.scs`, `tb_afe_receiver_tr.scs` and `tb_afe_transceiver_tr.scs` run the netlists under the checkers of `tb_afe_cdr.scs` / `tb_afe_pll.scs` / `tb_afe_receiver.scs` / `tb_afe_transceiver.scs` (`run_va_tests.sh _tr`).

## Running

```sh
python3 AFE/spice/tb/tb_cdr_tr.py                      # all cases, tt, 27 C, 1.8 V
python3 AFE/spice/tb/tb_cdr_tr.py vco --corner ss --temp 125 --vdd 1.62
python3 AFE/spice/tb/tb_pll_tr.py                      # vco, lock24, lock19, ref26: about 1 h
python3 AFE/spice/tb/tb_receiver_tr.py                 # seq, sqamp, dc0, dc2, dc5: about 8 min
python3 AFE/spice/tb/tb_receiver_tr.py --corner ss --temp 125 --vdd 3.0 --vddo 1.62
python3 AFE/spice/tb/tb_transceiver_tr.py              # seq, hs, fs, ls200, ls600, rx, dc: about 15 min
python3 AFE/spice/tb/tb_transceiver_tr.py --corner ff --temp -40 --vdd 3.6 --vddl 1.98
```

Needs ngspice (`apt install ngspice`; installed here on 2026-11-12, version 42). Netlists, logs and waveforms (`wrdata` text files) go to `build/spice/`. The script prints `TEST PASSED` / `TEST FAILED: <n> error(s)` like the other testbenches. Runtime on this machine (2 cores, cases in parallel): `vco` about 5 min, `lockp` about 20 min, `lock0` and `lockn` about 60 min. CDR: all four passed on 2026-11-12 (tt, 27 °C, 1.8 V); the VCO case was also run at ss / ff, 27 °C and at ss 125 °C 1.62 V / ff −40 °C 1.98 V. Results: `AFE/doc/cdr_schematic.md` section 4. PLL: `vco` about 10 min, each lock case about 30 min; all passed on 2026-11-12 at tt and at ff / −40 °C / 1.98 V; 24 MHz lock **fails** at ss / 125 °C / 1.62 V (−901 ppm, VCO out of range); results in `AFE/doc/pll_schematic.md` section 4. Receiver: all cases about 8 min per corner; passed on 2026-11-13 at tt, ss / 125 °C / 3.0 / 1.62 V and ff / −40 °C / 3.6 / 1.98 V (ss squelch margin only 5 mV); results in `AFE/doc/receiver_schematic.md` section 4. Transceiver: all cases about 15 min per corner; on 2026-11-14 (after the HS edge, ready-timer and parking fixes) tt and ff / −40 °C / 3.6 / 1.98 V passed, ss / 125 °C / 3.0 / 1.62 V **fails** one testbench tolerance (HS delay 1.34 ns against the 1.3 ns corner window, no USB limit); results in `AFE/doc/transceiver_schematic.md` section 4.

## Models: placeholder for xh018

The X-FAB xh018 models are confidential and not in this repo (`X-FAB/` holds only the digital views so far). `generic180.lib` uses typical published 0.18 µm values, not foundry data: tox 4.1 nm, Vth ≈ +0.37 / −0.39 V, Idsat ≈ 560 / 250 µA/µm, FO4 delay ≈ 85 ps. The 3.3 V cards `nch33` / `pch33` (added for the receiver's input stages): tox 7 nm, L ≥ 0.35 µm, Vth ≈ +0.68 / −0.66 V (constant current), Idsat ≈ 600 / 290 µA/µm at 3.3 V. The corners only shift Vth (±50 mV) and mobility (±8 %). Absolute numbers (VCO frequency, current, delays) will move with the real models; the topology and the loop design carry over.

To switch to xh018: replace the `.lib` line in the testbench with the X-FAB model include and its corner section, and map `nch` / `pch` / `nch33` / `pch33` to the xh018 1.8 V core and 3.3 V device names (they appear only in the wrappers `nfet` / `pfet` / `nfet33` / `pfet33` of `afe_cells.sp`, which also set the diffusion geometry). Resistors and capacitors are ideal elements with the intended device in a comment (high-ohmic poly, MIM, NMOS capacitor); replace them with the PDK devices at the same time. Then retune the shared VCO (`RC`, `RF`, `XMOF` multiplier) to the targets in the schematic documents and rerun both testbenches, and keep `X-FAB/` out of git.
