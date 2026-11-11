# AFE/ams — Spectre AMS testbenches (phase A8)

*Created 2026-11-11. Status: written, not run yet: there is no AMS simulator (Cadence Xcelium + Spectre, `xrun -ams`) on the development machine. The digital half of every AMS testbench and its sequence run on every `./run_tests.sh` through an Icarus shadow (below), and `check_ams_netlist.py` checks the AMS netlists statically. Expect a few compile fixes on the first run, mainly in the connect modules.*

These testbenches co-simulate the digital RTL of the repository (`usb_*.v`) with the Verilog-A AFE models of `AFE/veriloga/`, which is phase A8 of `AFE_INTEGRATION_PLAN.md`. Later, the same tops can take the transistor-level blocks in place of the models (AMS Designer configuration, `config` / `amsd` block).

## Files

| File | Content |
|---|---|
| `lib/usb_connect.vams` | Connect modules `usb_l2e` (digital → electrical: 0 / 1.8 V, 50 ps edges, 50 Ω), `usb_e2l` (electrical → digital: thresholds 0.8 / 1.0 V around the models' 0.9 V), `usb_bidir`, and the connect rules `usb_cr` |
| `lib/ams_prims.va` | `ams_vdc`, `ams_vsup` (supply ramp switched by a logic pin), `ams_res`, `ams_cap`: the tops need no Spectre primitive cells |
| `ams_phy_end.v` | One end of the line (device or host): the digital PHY below ULPI (`usb_mode_term_ctrl`, `usb_tx_path`, `usb_afe_tx_if`, `usb_afe_rx_if`, `usb_rx_status_sync`, `usb_line_state`, `usb_rx_datapath`) plus the Link model's hooks (registers, byte feeder, receive monitor), with the AFE pins as plain digital ports. Plain Verilog-2005 |
| `ams_link_seq.vh` | Link models, sequence and checks of the line test (included in the top module) |
| `tb_ams_link.vams` + `amscf_link.scs` | Two ends (device, host +400 ppm), each with `afe_transceiver`, `afe_receiver`, `afe_cdr` on one DP / DM: attach, FS packets both ways, reset, device chirp K (0.65–0.75 V, no J), host chirps, switch to HS (0.36–0.44 V), HS packets both ways. About 85 µs |
| `ams_pwr_seq.vh` | Stimulus and checks of the power-up test |
| `tb_ams_pwr.vams` + `amscf_pwr.scs` | VDD33 ramp → two `afe_ldo` (VDD18 with POR_N, VDD18A enabled by the sequencer) → `afe_pll` → `usb_pwr_seq`, `usb_pll_lock_det`, `usb_clk_gen`: POR, PG18A and VDD18A level, lock within 100 µs, CLKOUT 60 MHz ± 0.1 % with 4 + 4 cycles, low power with CLKOUT and PLL stopped, wake and relock. About 450 µs |
| `check_ams_netlist.py` | Static check of the AMS tops: the header command's files exist, every instance uses named ports that its module has, each port once, none left open, the connect rules exist |
| `run_ams_tests.sh` | Runner: static check, then the header `xrun` command of each `tb_ams_*.vams` in parallel |

The Icarus shadows are in the repository root, next to the other testbenches:

| Shadow | Same as | Differs in |
|---|---|---|
| `tb_ams_link_shadow.v` | `tb_ams_link.vams`: same `ams_phy_end` instances, same `ams_link_seq.vh` | AFE = `afe_term_bm`, `afe_hs_tx_bm`, `afe_fsls_bm`, `afe_hs_rx_bm`, `afe_squelch_bm`, `afe_cdr_bm` on `afe_line_bm` |
| `tb_ams_pwr_shadow.v` | `tb_ams_pwr.vams`: same DUT chain, same `ams_pwr_seq.vh` | PLL = `afe_pll_bm`; the LDOs are delays with the `afe_ldo.va` default timing |

So a failure that shows only in Spectre AMS points at the Verilog-A models, the connect modules or the AMS netlist, not at the RTL or the sequence. The sequence files access the line through macros (`` `AMS_VDP`` / `` `AMS_VDM`` / `` `AMS_V18A``): `$cds_get_analog_value("top.net")` in AMS, the models' real buses in the shadows.

## Running

```sh
AFE/ams/run_ams_tests.sh              # all AMS testbenches
AFE/ams/run_ams_tests.sh link         # only tb_ams_link
XRUN=/path/to/xrun AFE/ams/run_ams_tests.sh
XRUN_OPTS="-define AMS_NPKT=20 -define AMS_NFS=4" AFE/ams/run_ams_tests.sh link
```

Each testbench's header holds its complete `xrun` command, with paths relative to the repository root. The runner runs it from the root with `-xmlibdirpath build/ams/<tb>`, `-l build/ams/<tb>/xrun.log`, `-spectre_args "-raw build/ams/<tb>/psf"` and a Tcl file that probes the top two levels into `build/ams/<tb>/waves.shm`. It checks the `TEST PASSED` / `TEST FAILED` line, not xrun's exit status. Without `xrun` it runs only the static check and reports SKIP.

Command pattern (from `tb_ams_pwr.vams`):

```sh
xrun -ams -timescale 1ns/1ps -access +r -incdir AFE/ams \
     -analogcontrol AFE/ams/amscf_pwr.scs -amsconnrules usb_cr \
     AFE/ams/lib/usb_connect.vams AFE/ams/lib/ams_prims.va \
     AFE/veriloga/afe_ldo.va AFE/veriloga/afe_pll.va \
     usb_pwr_seq.v usb_pll_lock_det.v usb_clk_gen.v \
     AFE/ams/tb_ams_pwr.vams -top tb_ams_pwr
```

Notes for the first run:

- **Disciplines.** The RTL has no discipline declarations, so AMS Designer resolves them. If elaboration complains about nets without a discipline between the RTL and the models, add a default discipline for the digital files (the xrun option for it depends on the release) or `` `default_discipline logic`` in front of the RTL files.
- **Connect rules.** If the site prefers Cadence's own `connectLib` (`ConnRules_18V_full_fast` or an `amsd { ie vsup=1.8 ... }` block in the control file), replace `-amsconnrules usb_cr` and drop `lib/usb_connect.vams`. Keep the 0.9 V threshold.
- **Run time.** Most of it is the 480 Mbit/s edges (`tb_ams_link`, HS part) and the 480 MHz VCO (`tb_ams_pwr`, 450 µs). `maxstep` in `amscf_link.scs` can be raised if the CDR still locks.

## Adding an AMS testbench

1. Put the digital part in a plain Verilog module (or reuse `ams_phy_end.v`), and the stimulus and checks in an `ams_*_seq.vh` that uses only those instances and macros for analog values.
2. Write `tb_ams_<name>.vams` (Verilog-A models + named ports + `` `include "ams_<name>_seq.vh"``) with its `xrun` command in the header, and `amscf_<name>.scs`.
3. Write the shadow `tb_ams_<name>_shadow.v` in the repository root with the `afe_*_bm.v` models, the same `.vh` and an `iverilog` header command (`-I AFE/ams`), so `./run_tests.sh` covers it.
4. Run `python3 AFE/ams/check_ams_netlist.py` and `./run_tests.sh <name>_shadow`.

## Free simulators

There is no free Spectre / AMS Designer. Gnucap with `gnucap-modelgen-verilog` (installed here on 2026-11-11 in `/usr/local`, sources in `/opt/src`) is the only free simulator that aims at behavioural Verilog-AMS. In its current development version it compiles `lib/ams_prims.va` and generates code for `afe_ldo.va`, but it cannot run the AFE models yet: `transition()` is unfinished there ("incomplete: new_transition", so the LDO testbench's stimulus never reaches the circuit), `idtmod` (PLL) and `last_crossing` (CDR) are missing, the receiver / transceiver hit unfinished filter code, and connect modules with digital blocks don't parse. Worth retrying with later Gnucap releases.
