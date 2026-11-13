# AFE — Idealized Verilog-A Models

*Created 2026-11-11. Status: first version, with a self-checking Verilog-A testbench per block (`veriloga/tb/`). Neither the models nor the testbenches **have been simulated yet**: no Verilog-A simulator is installed on the development machine. They have only been reviewed and lint-checked (structure, declarations, netlist port counts). The first run in Spectre / Spectre AMS (or another simulator with analog events) is still open. See [Verification status](#verification-status).*

This directory holds the analog side of the USB 2.0 PHY:

| Path | Content |
|---|---|
| `view analog_block USB 2.0 High.md` | The analog team's description of the existing transistor-level blocks: HS RX, HS TX, and the PLL-assisted CDR |
| `veriloga/*.va` | Idealized Verilog-A models of the AFE blocks, aligned with the digital RTL |
| `veriloga/tb/` | One testbench per block: a Verilog-A stimulus / checker module (`tb_afe_*.va`), a Spectre netlist (`tb_afe_*.scs`), shared macros (`tb_afe_common.vams`) and the runner `run_va_tests.sh` |
| `spice/` | Transistor-level schematics as SPICE netlists (ngspice and Spectre), with a generic 180 nm placeholder model and ngspice testbenches; so far the CDR (`afe_cdr_tr.sp`, [doc/cdr_schematic.md](doc/cdr_schematic.md)) and the PLL (`afe_pll_tr.sp`, [doc/pll_schematic.md](doc/pll_schematic.md)), sharing one VCO cell, the HS receiver with squelch and disconnect (`afe_receiver_tr.sp`, [doc/receiver_schematic.md](doc/receiver_schematic.md)) and the line transceiver (`afe_transceiver_tr.sp`, [doc/transceiver_schematic.md](doc/transceiver_schematic.md)); see [spice/README.md](spice/README.md) |
| `ams/` | Spectre AMS (xrun -ams) testbenches with the digital RTL, connect rules, runner; see [ams/README.md](ams/README.md) |
| `doc/*.md` | One document per model: pins, behaviour, parameters, alignment with the digital side |

The Verilog-A models are the analog-simulator counterpart of the event-driven Verilog models `afe_*_bm.v` in the repository root. Those models run in Icarus with the digital testbenches. The Verilog-A models are for the mixed-signal phase **A8** of `AFE_INTEGRATION_PLAN.md`: the digital netlist co-simulated with analog blocks in Spectre AMS. They can stand in for blocks that are not designed yet, and they serve as the reference that the transistor-level blocks are checked against.

## Blocks

| File | Modules | Block | Document | Verilog model with the same behaviour |
|---|---|---|---|---|
| `veriloga/afe_pll.va` | `afe_pll` | PLL (lower loop of the CDR block): PFD, charge pump, R2/C3/C4 filter, VCO, ÷N (fixed ÷20 or from REFSEL), 480 MHz `clk_bit` | [doc/pll.md](doc/pll.md) | `afe_pll_bm.v` |
| `veriloga/afe_cdr.va` | `afe_cdr` | CDR (upper loop): Alexander bang-bang PD, charge pump, R8/C2/C1 filter, VCO with coarse input from the PLL, retimed data output | [doc/cdr.md](doc/cdr.md) | `afe_cdr_bm.v` |
| `veriloga/afe_transceiver.va` | `afe_hs_tx`, `afe_fsls_xcvr`, `afe_term`, `afe_transceiver` | Line transceiver: HS current driver (the HS TX block), FS/LS drivers and receivers, 1.5 kΩ pull-up / 45 Ω HS terminations / 15 kΩ pull-downs | [doc/transceiver.md](doc/transceiver.md) | `afe_hs_tx_bm.v`, `afe_fsls_bm.v`, `afe_term_bm.v` |
| `veriloga/afe_receiver.va` | `afe_hs_rx`, `afe_squelch`, `afe_receiver` | HS receiver (the differential Schmitt-trigger HS RX block), squelch and disconnect envelope detectors | [doc/receiver.md](doc/receiver.md) | `afe_hs_rx_bm.v`, `afe_squelch_bm.v` |
| `veriloga/afe_ldo.va` | `afe_ldo` | 3.3 V → 1.8 V LDO with UVLO, soft start, power-good and power-on reset | [doc/ldo.md](doc/ldo.md) | none (no digital model yet) |

## How the blocks connect

```
                     VDD33 (3.3 V)
                       │
            ┌──────────┴───────────┐
            │ afe_ldo (x2)         │──VDD18──► digital core, ULPI pads
            │                      │──VDD18A─► afe_pll, afe_cdr
            └─ PWR_GOOD, POR_N ────┘──► pwr_good, por_n (power sequencer, rst_n of usb_clk_gen / usb_pll_lock_det)

 24 MHz ──CDR_FREF──► afe_pll ──CLK_BIT_A──► clk_bit (whole digital core; usb_clk_gen → ce60, CLKOUT)
                        │  ├─────REF_DIG───► ref_clk of usb_pll_lock_det
             PLL_EN, REFSEL1/0 ◄─────────────── pll_en, refsel (digital)
                        │
                 CDR_CH_OUT_PLL (coarse control voltage)
                        ▼
                 CDR_V_IN_2
 RX_OUT_P ──CDR_DATA──► afe_cdr ──CLK_RX──► clk_rx    ┐
                        │      └──HS_RXD──► hs_rxd_a  ├─ usb_afe_rx_if ─► usb_rx_datapath
                CDR_EN ◄──────────────────── cdr_en   │
                                                       │
 DP/DM ──RX_IN_P/N──► afe_receiver ──SQUELCH_A──► squelch_a
                        │          ──DISC_A────► host_disc
                        │          ──RX_OUT_P──► CDR_DATA (above)
                 RX_EN ◄──────────────────────── rx_en_hs

 usb_afe_tx_if ─hs_tx_p/n, hs_tx_en────► afe_transceiver ──TX_OUT_P/N──► DP / DM
               ─fs_oe/dat/se0/ls───────►   (afe_hs_tx, afe_fsls_xcvr, afe_term)
 usb_rx_datapath ◄─rxrcv, rxdp, rxdm────
 (future usb_mode_term_ctrl) ─DP_PULLUP_EN_A, HS_TERM_EN_A, PD_EN_A0/1─►
```

Signal names, directions, reset / isolated values and timing come from `DOC/afe_interface_spec.md` (draft 0.1). Analog pins keep the analog team's names (`TX_IN_P`, `CDR_FREF`, `CDR_CH_OUT_PLL`, …). Pins the analog design does not have yet carry the spec's `_A` names (`SQUELCH_A`, `FS_OE_A`, …) or the proposed names (`RX_EN`, `CDR_EN`, `PLL_EN`, `HS_RXD`, `REF_DIG`).

## Conventions shared by all models

- **Units:** SI (seconds, volts, amperes, hertz). The `afe_*_bm.v` models use ns; the defaults here are the same values in seconds.
- **Logic pins** are 1.8 V CMOS: inputs switch at `vth_logic` (0.9 V) against the block's ground. Outputs swing from ground to the block's logic supply (`VDD18` / `VDD18A` / `RX_VDDO`, or `VOUT` for the LDO) and have edges of `t_rf`. The 3.3 V ↔ 1.8 V crossings at 480 Mbit/s are inside the blocks, as proposed in Q8.
- **Enables and supplies:** each block checks its enable pin and its supply (`vdd_min`). When off, it drives the **isolated values** from the spec (`HS_RXD` = 1, `SQUELCH_A` = 1, `DISC_A` = 0, `RXRCV_A` = 1, `RXDP_A` = `RXDM_A` = 0, `RX_OUT_P` = 0), so power-down and isolation sequences can be checked.
- **Idealized:** no transistor effects, no temperature or corner dependence, no mismatch unless a parameter injects it. Default noise and jitter are 0. Defaults equal the `afe_*_bm.v` parameters, which are the digital side's working assumptions (A0 proposals) until the analog sign-off values arrive (correlation table, plan 5.3).
- **Parameters** are static Verilog-A parameters. Override them per instance in the netlist. The `afe_*_bm.v` models change some values during a run (`STEP`, `V_HYS`, `f_off`, …); here a sweep is a separate simulation.
- **Module names** are `afe_*` without `_bm`. They never start with `usb_`, so they cannot clash with the digital modules in an AMS netlist.
- **Simulator constructs:** `cross`, `timer`, `transition`, `idtmod`, `last_crossing`, `ddt`, `$bound_step`, `$rdist_*`, and structural instantiation of Verilog-A modules (in the `afe_receiver` / `afe_transceiver` wrappers). Spectre supports all of these. Compact-model compilers such as OpenVAF (ngspice OSDI) do not support analog events, so they can't run these models.

## Using the models in Spectre

```spectre
// afe_example.scs: excerpt, node names as in the digital netlist
simulator lang=spectre
ahdl_include "AFE/veriloga/afe_ldo.va"
ahdl_include "AFE/veriloga/afe_pll.va"
ahdl_include "AFE/veriloga/afe_cdr.va"
ahdl_include "AFE/veriloga/afe_receiver.va"
ahdl_include "AFE/veriloga/afe_transceiver.va"

V33   (vdd33 0)  vsource dc=3.3
LDOD  (vdd33 vdd18  0 vdd33 pwr_good  por_n)    afe_ldo
LDOA  (vdd33 vdd18a 0 ldo_en pg_a      porn_a)  afe_ldo
COD   (vdd18  0) capacitor c=1u
COA   (vdd18a 0) capacitor c=1u
XO    (fref 0) vsource type=pulse val0=0 val1=1.8 period=41.6667n width=20.8333n rise=0.5n fall=0.5n
PLL   (fref pll_en refsel1 refsel0 clk_bit ref_dig vctl_pll vdd18a 0) afe_pll
CDR   (rx_out_p cdr_en vctl_pll clk_rx hs_rxd_a vctl_cdr vdd18a 0)   afe_cdr
RX    (dp dm rx_en_hs vref_rx rx_out_p rx_out_n squelch_a host_disc vdd33 0 vdd18) afe_receiver
XCVR  (hs_tx_p hs_tx_n hs_tx_en i5u vref_tx tx_cap_p tx_cap_n \
       fs_oe fs_dat fs_se0 fs_ls fs_rx_en rxrcv rxdp rxdm \
       dp_pullup_en hs_term_en pd_en0 pd_en1 dp dm vdd33 vdd18 0) afe_transceiver
```

Port order is the order in each module header. The far end of the link (host or device) is another `afe_transceiver` + `afe_receiver` pair on the same `dp` / `dm`, or a USB pattern generator. A cable model, if needed, is a transmission line between the two ends.

## Testbenches

Each block has a self-checking testbench in `veriloga/tb/`, in the same style as the Verilog testbenches of the repository:

- `tb_afe_<block>_chk` (in `tb_afe_<block>.va`) is a Verilog-A module that drives the block's inputs and supplies, measures its outputs, and checks them against the spec values. It runs a fixed sequence of steps (`@(timer)`) and counts failed checks in `errors`. Each check prints `ok <name> = <value>` or `ERROR at <t>: <name> = <value> (expected <lo> .. <hi>)`.
- At the end it prints **`TEST PASSED`** or **`TEST FAILED: <n> error(s)`** and stops the run (`$finish`). If the tran stop time is reached first, which acts as the watchdog, it prints **`TEST FAILED: timeout`**.
- `tb_afe_<block>.scs` is the Spectre netlist. It `ahdl_include`s the model and the checker, connects them (plus passive loads or a second model instance where needed), saves all public nodes and runs `tran`.
- `./run_va_tests.sh [name ...]` runs all testbenches, or those whose name contains an argument, in parallel with `$SPECTRE` (default `spectre`). It writes logs and raw data to `build/va/<testbench>/`, checks the result line rather than the exit code, and exits non-zero on any failure. Without a simulator it reports every testbench as `SKIP`.

| Testbench | Checks | Sim. time |
|---|---|---|
| `tb_afe_pll` | Settling to ±0.08 % ≤ 45 µs at 24 MHz / ÷20 and ≤ 30 µs at 19.2 MHz / ÷25 (spec 4.3); the `usb_pll_lock_det` window count (`CLK_BIT_A` edges per 256 `REF_DIG` periods: 5120 / 6400) exact to ±1 after settling; 480 MHz; control voltage 0.9 V; `PLL_EN` = 0 stops the clock low, `REF_DIG` keeps running, the filter discharges; 26 MHz with ÷20 never gives a window inside 4726 ± 5 (VCO at its 500 MHz limit) | 225 µs |
| `tb_afe_cdr` | Packet generator (SYNC 12 / 32 bits, PRBS7, EOP, a random start phase per packet). Lock time per packet, in bits from the first transition until the sampling instant stays ≥ 0.15 UI from every data edge: ≤ 6 bits (spec 4.2, `HS_ZMIN` 4 / `LOCK_DLY` 2), with mean and worst case reported; 1027-byte packets at ±1000 ppm without loss of lock or a bit slip; `HS_RXD` equals the previous sample; `HS_RXD` setup ≥ 0.4 ns / hold ≥ 0.1 ns; free-running clock 480 MHz ± 0.25 %; `CDR_EN` = 0 → `CLK_RX` low, `HS_RXD` = 1 | 85 µs |
| `tb_afe_transceiver` | FS attach (DP = 3.0 V), HS J / K = ±400 mV into 2 × 45 Ω, no current before `t_en`, 10–90 % edge 0.5 ns, `TX_IN` → line delay, P = N split, chirp 800 mV into one 45 Ω, `TX_EN` = 0; FS J / K / SE0 levels and receivers, FS rise 4–20 ns, `RXRCV_A` delay, LS rise 75–300 ns; device pull-ups / pull-downs; isolated receiver values (`FS_RX_EN_A` = 0, VDD33 low). The far end is an `afe_term` | 2.6 µs |
| `tb_afe_receiver` | Hysteresis thresholds ±10 mV, `RX_OUT_P` delay; squelch release 4 ns after a 400 mV alternating pattern starts, assertion 12 ns after it stops; no release at 90 mV, release at 160 mV, a 2 ns burst ignored; disconnect at 650 mV (static) after 4 ns, not at 500 mV; isolated outputs (`RX_EN` = 0, `RX_VDD` low) | 2.7 µs |
| `tb_afe_ldo` | Start-up from a 100 µs VIN ramp: off below the 2.7 V UVLO, soft start, `PWR_GOOD` 10 µs after 1.62 V, `POR_N` 100 µs later; load regulation at 10 / 40 mA; current limit into 10 Ω with `PWR_GOOD` / `POR_N` falling, then recovery; line regulation −3 mV for −0.3 V; UVLO off at 2.4 V and restart; `LDO_EN` = 0 discharges VOUT | 1.95 ms |

To vary a model parameter, override it on the `DUT` line of the netlist (for example `DUT (...) afe_cdr jit_rms=10p t_amb=30p`). Where a check depends on that parameter, override the matching parameter of `CHK` as well (`t_en`, `v_hys`, `t_on`, …).

## Verification status

| Check | Status |
|---|---|
| Structural lint: `begin`/`end` and `module`/`endmodule` balanced, every assigned variable declared, brackets balanced | done (script, 2026-11-11) |
| Testbenches written (one per block, `veriloga/tb/`); netlist node counts checked against the module port lists | done (2026-11-11) |
| Compile the models and testbenches, run `run_va_tests.sh` in Spectre | **open**: no simulator here. Expect a few syntax fixes on the first compile, and expect some check windows to need adjusting once real waveforms show up |
| Spectre AMS with the digital netlist | testbenches written (2026-11-11, `AFE/ams/`: `tb_ams_link` two-ended line FS + chirp + HS, `tb_ams_pwr` LDOs + PLL + power sequencer), statically checked, their digital half and sequences pass in the Icarus shadows; **not run**: no AMS simulator here |
| Correlation with `afe_*_bm.v` | open: same defaults by construction, not compared in simulation |
| Transistor-level PLL `spice/afe_pll_tr.sp` | simulated in ngspice on generic 180 nm models (2026-11-12, [doc/pll_schematic.md](doc/pll_schematic.md) section 4); `veriloga/tb/tb_afe_pll_tr.scs` runs it under the `tb_afe_pll` checker in Spectre, **not run** |
| Transistor-level receiver `spice/afe_receiver_tr.sp` | simulated in ngspice on generic 180 nm models (2026-11-13, [doc/receiver_schematic.md](doc/receiver_schematic.md) section 4); `veriloga/tb/tb_afe_receiver_tr.scs` runs it under the `tb_afe_receiver` checker in Spectre, **not run** |
| Transistor-level transceiver `spice/afe_transceiver_tr.sp` | simulated in ngspice on generic 180 nm models (2026-11-13, [doc/transceiver_schematic.md](doc/transceiver_schematic.md) section 4); `veriloga/tb/tb_afe_transceiver_tr.scs` runs it under the `tb_afe_transceiver` checker in Spectre, **not run** |
| Transistor-level CDR `spice/afe_cdr_tr.sp` | simulated in ngspice on generic 180 nm models (2026-11-12, [doc/cdr_schematic.md](doc/cdr_schematic.md) section 4); `veriloga/tb/tb_afe_cdr_tr.scs` runs it under the `tb_afe_cdr` checker in Spectre, **not run** |

## Open points that change these models

The questions are in `DOC/afe_interface_spec.md` section 8.

| Q | Affects |
|---|---|
| Q1 | `afe_cdr`: retimed data pin `HS_RXD` and its timing; a 1:4 demultiplexed output (section 7.2 of the spec) would add 4 data pins and a divided clock |
| Q2 | `afe_cdr` loop values (`icp`, `r8`, `c2`), `afe_squelch` `t_sq_on` / `t_sq_off` |
| Q3 | Polarity in `afe_hs_tx` (`TX_IN_P` = 1 → DP), `afe_hs_rx` (`RX_OUT_P` = 1 ↔ DP > DM) |
| Q4 | `afe_hs_tx` `t_en`, `t_dly`, behaviour while `TX_EN` = 0 |
| Q5 | `afe_hs_rx` `v_hys`, `v_off`; whether it also serves as the FS/LS `RXRCV_A` |
| Q6 | `afe_pll` `prog_div`, `div_*` |
| Q8 | Output supply `RX_VDDO` of the receiver; 1.8 V logic thresholds of the transceiver inputs |
| Q9 | `afe_hs_tx` `bias_mode` (`TX_I_5U`, `TX_VREF`), `RX_VREF` |
| Q10 | `afe_hs_tx` `TX_CAP_P/N` (`r_cap`) |
| Q13 | `afe_ldo`: whether the LDO is on chip at all |
