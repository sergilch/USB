# AFE Integration Plan — Connecting the Analog Front End to the Digital Core

*Created 2026-11-10. Based on the analog team's block description (HS RX, HS TX, PLL-assisted CDR; kept locally in `AFE/`), the AFE-interface diagram (`DOC/Diagramm/afe_interface`), the USB3320 datasheet, and the digital RTL as of commit `baf2745`. Companion to `WORK_PLAN.md`, which covers the digital section; this plan covers the boundary and everything still missing between the digital core and DP / DM.*

---

## 1. Goal

A working USB 2.0 PHY needs the digital core (ULPI controller, TX / RX datapaths, register file: done or planned in `WORK_PLAN.md`) and an analog front end that turns its bit streams into USB line signalling and back. Three analog blocks already exist. This plan:

1. defines the electrical and logical interface between them and the digital core (section 3),
2. lists the open questions to settle with the analog team (section 4),
3. lists what is still missing, on both sides, for a complete PHY (section 5),
4. orders the integration and verification work (sections 6–8).

---

## 2. What exists

### 2.1 Analog blocks (as described by the analog team)

| Block | Supply | Pins | Function |
|---|---|---|---|
| **HS RX** | 3.3 V | `RX_IN_P/N` in; `RX_OUT_P/N` out (CMOS, two-inverter buffers); `RX_VREF`; `RX_VDD`, `RX_GND` | Differential Schmitt-trigger receiver (hysteresis by positive feedback), reference network `RX_R0`/`RX_R1`. Modelled on the USB3320 input stage. No enable pin. |
| **HS TX** | 3.3 V | `TX_IN_P/N` in; `TX_OUT_P/N` out; `TX_EN`; `TX_I_5U`; `TX_VREF`; `TX_CAP_P/N` (external capacitors); `TX_VDD`, `TX_GND` | Analog CMOS differential driver, 480 Mbit/s, output high level 360–440 mV. Bias from `TX_VREF`; `TX_I_5U` "selects the operating mode". |
| **CDR + PLL** | 1.8 V | `CDR_FREF` in; `CDR_DATA` in; recovered clock out | Lower loop: PFD, charge pump, filter (`CDR_R2`/`C3`/`C4`), ring VCO, fixed ÷20 → f_VCO = 20 · f_REF. Upper loop: Alexander (bang-bang) phase detector on `CDR_DATA`, charge pump, filter (`CDR_R8`/`C2`/`C1`), second ring VCO. The PLL control voltage `CDR_CH_OUT_PLL` drives the CDR VCO coarse input `CDR_V_IN_2`, so the CDR VCO sits near the data rate even without data. |

### 2.2 Digital side today (ports the AFE must connect to)

| Direction | Signal(s) | Module | Meaning |
|---|---|---|---|
| core → AFE | `txd`, `tx_en`, `tx_se0`, `tx_speed[1:0]` | `usb_ulpi_phy_top` (from `usb_tx_path`) | Line state per bit on `clk_bit`: J = 1 / K = 0; `tx_se0` = SE0 (FS/LS EOP); `tx_en` = drive the line; `tx_speed` = XcvrSelect (00 HS, 01 FS, 10 LS). HS: one bit per `clk_bit` cycle. FS/LS: bits held for 40 / 320 cycles. |
| AFE → core | `clk_rx`, `hs_rxd`, `hs_squelch`, `hs_cdr_lock` | `usb_rx_datapath` → `usb_rx_hs_frontend` | HS: recovered clock and retimed data, squelch (1 = no signal), CDR lock. Assumes the CDR free-runs while there is no data (assumption D1). |
| AFE → core | `rxrcv`, `rxdp`, `rxdm` | `usb_rx_datapath` → `usb_rx_fsls_frontend` | FS/LS: differential receiver and single-ended DP / DM receivers, asynchronous; recovered by a DPLL on `clk_bit` (D2). |
| AFE → core | `linestate[1:0]`, `host_disc`, `a_vbus_vld`, `sess_vld`, `sess_end`, `id_gnd` | `usb_ulpi_phy_top` | Currently top-level inputs; to be derived from receiver / comparator outputs in WORK_PLAN phases 3–4. |
| core → AFE | `xcvrselect`, `termselect`, `opmode`, `suspendm`, `otg_ctrl` | `usb_ulpi_phy_top` | Raw register fields; the termination / pull / power controls derived from them are not implemented yet (phases 3–6). |
| clock | `clk_bit` 480 MHz, `ce60` | all | The core needs the PLL's 480 MHz clock; `ce60` and the 60 MHz `CLKOUT` are derived from it (WORK_PLAN 5.2). |

The digital core runs at 1.8 V on the xh018 D_CELLS_JIHD library. `run_synth.sh` maps all top levels onto it, but timing at 480 MHz has not been analysed yet.

---

## 3. Interface definition (target)

Signals on the analog side keep the analog team's names; `_A` marks the AFE-interface pin of the diagram. Every analog pin listed in section 5 as *missing* is marked **(new)**.

### 3.1 HS transmit path

```
usb_tx_path ─txd,tx_en,tx_se0,tx_speed─► usb_afe_tx_if (new, digital, clk_bit) ─► level shift 1.8→3.3 V ─► HS TX
                                          · TX_IN_P = txd_r, TX_IN_N = ~txd_r, from two flops on the same clk_bit edge
                                          · TX_EN lead / lag around the packet (programmable, in bit times)
                                          · idle clamp: TX_IN_P/N static, TX_EN low, when disabled or isolated
                                          · HS vs. FS/LS driver select, chirp mode (OpMode 10)
```

| Item | Target |
|---|---|
| Data mapping | `TX_IN_P` high = J. For HS, J means `TX_OUT_P` drives the 17.78 mA current (DP high). The analog team must confirm the polarity (I3). |
| Skew | `TX_IN_P` / `TX_IN_N` come from flops on one clock edge with matched routing; the maximum P/N skew at the TX input must come from the analog team, so that the boundary keeps HS eye margin. |
| Driver enable | The HS current driver needs time to settle. The digital adds a programmable lead: `TX_EN` rises *N* bit times before the first SYNC bit (data delayed by an *N*-bit shift register on `clk_bit`), and falls *M* bit times after the EOP. *N* and *M* go in a vendor register (Phase 6.4). Defaults follow from the TX enable time measured in simulation (I4). |
| Idle | While `TX_EN` is low the HS driver must not disturb the line, and in HS idle the line is held by the 45 Ω terminations (section 5.1). |

### 3.2 HS receive path

```
DP/DM ─► HS RX ─RX_OUT_P─► level shift 3.3→1.8 V ─► CDR_DATA ─► CDR ─► recovered clock + retimed data
                                                                     │
                     squelch detector (new) ─SQUELCH_A─┐             ▼
                                                       └─► usb_rx_hs_frontend (clk_rx = CDR clock, hs_rxd = CDR data)
                                                           ─► elastic buffer ─► clk_bit domain
```

| Item | Target |
|---|---|
| CDR outputs | **Recovered clock** (`clk_rx`) and **retimed data** (`hs_rxd`): the Alexander phase detector already samples the data, so its sampled data bit must be brought out next to the clock, with a defined setup / hold relative to the clock edge that the digital uses (I1). The block description shows only a clock output. |
| Free-running | With no data (squelch) the CDR VCO is held near 480 MHz by the PLL control voltage. This matches the digital assumption D1: `clk_rx` keeps running and the elastic buffer write side stays alive. |
| Lock time | Through five hubs a receiver can see a SYNC as short as 12 bits. The digital SYNC detector needs `HS_ZMIN` = 6 alternating bits plus the final K-K. So the CDR (plus squelch response) must deliver correct bits within **about the first 5 bit times** after the line becomes active. That is a hard requirement on the CDR loop (bang-bang + coarse loop) and must be shown in simulation (I2). |
| Lock indication | The CDR has no lock detector. `hs_cdr_lock` will be generated digitally: a fixed delay after squelch drops (default sized from the simulated lock time, programmable), because a frequency check alone can't tell lock from free-running. |
| Frequency tolerance | Host ±500 ppm, own reference ±500 ppm → the CDR must track ±1000 ppm. The elastic buffer (16 events) already covers this for maximum-length packets (`tb_usb_rx_datapath`). |

### 3.3 FS / LS paths

Today only HS blocks exist. FS / LS need transmit drivers and single-ended receivers that are not in the AFE yet (section 5.1). The digital interface is already fixed by `usb_rx_fsls_frontend` (`rxrcv`, `rxdp`, `rxdm`) and, on the TX side, will use a USB 1.1 transceiver style interface from `usb_afe_tx_if`: `FS_OE` (drive), `FS_DAT` (J / K), `FS_SE0`, `FS_LS` (slew-rate select) **(new)**. Whether the HS RX block, at another bias point, can also serve as the FS/LS differential receiver (`rxrcv`) is question I5.

### 3.4 Clocks and reference

| Item | Target |
|---|---|
| Reference | `CDR_FREF` from a crystal oscillator / REFCLK input buffer **(new)**. With the fixed ÷20, only **24 MHz** gives 480 MHz. The register / pin `REFSEL` (19.2 / 24 / 26 MHz in the AFE diagram) needs a programmable feedback divider (÷25 for 19.2 MHz; 26 MHz is not an integer ratio and needs a fractional divider or a different VCO plan), or the product supports 24 MHz only (I6). |
| `clk_bit` | 480 MHz from the PLL VCO (lower loop), buffered into the digital clock tree. Duty cycle and jitter at the digital clock root to be specified. |
| `ce60` / `CLKOUT` | Generated digitally from `clk_bit` (÷8, WORK_PLAN 5.2). `CLKOUT` 60 MHz leaves through a BBSUD8F pad. |
| PLL lock | No lock output exists. Planned digitally: `usb_pll_lock_det` counts `clk_bit` cycles over 2^k reference cycles and compares with 20 · 2^k ± tolerance, with N consecutive good windows for lock and a loss-of-lock flag. Needs the reference clock routed into the digital (I7). |
| Enables | `PLL_EN`, `CDR_EN` **(new)**: needed for suspend (ULPI low-power mode turns off the PLL) and for an ordered power-up. |

### 3.5 Supplies and level shifting

The TX and RX blocks run at 3.3 V, the CDR and the digital at 1.8 V. That means:

- **480 Mbit/s level shifters** on `TX_IN_P/N` (1.8 → 3.3 V, matched pair) and on `RX_OUT_P` → `CDR_DATA` (3.3 → 1.8 V). Standard-cell level shifters are usually far too slow and asymmetric for 480 Mbit/s; these must be analog-designed cells, ideally inside the TX / RX blocks (an HS TX pre-driver with 1.8 V inputs; an RX output stage at 1.8 V). Recommendation I8.
- **Slow control signals** (enables, trims, terminations, status) use library level shifters / isolation cells, controlled by `iso_en` / `ls_en` from the power sequencer (WORK_PLAN 5.4, 6.5). Check which level-shifter / isolation cells the xh018 PDK offers.
- **Power-down isolation:** when the 3.3 V domain is off, every 1.8 V input fed from it must be clamped (isolation cells), and outputs into it must not back-power it.

---

## 4. Open questions for the analog team

| # | Topic | Question | Why it matters / proposal |
|---|---|---|---|
| I1 | CDR data output | Can the Alexander PD's sampled data be brought out as `hs_rxd`, and on which `clk_rx` edge is it valid? | The digital HS front end samples `hs_rxd` on `clk_rx`. Without a retimed data output the digital would have to sample the asynchronous `RX_OUT` itself at 480 MHz, which can't work reliably. |
| I2 | CDR lock time | Simulated lock time from squelch release (worst corner, ±1000 ppm, worst initial phase)? | Must leave at least 7 usable SYNC bits of a 12-bit SYNC (section 3.2). If it can't, the SYNC detector threshold `HS_ZMIN` has to come down, which raises the false-SYNC risk. |
| I3 | Polarities | `TX_IN_P` high = DP high? `RX_OUT_P` high = DP > DM? | Fixes the J / K mapping at the boundary. |
| I4 | TX timing | `TX_EN` to stable output current; output delay from `TX_IN` to `TX_OUT`; behaviour while `TX_EN` is low (high impedance? current dumped?). | Sets the lead / lag defaults (3.1), and the USB TX start-delay budget. |
| I5 | RX role | Is the Schmitt receiver the HS receiver only, or also the FS/LS differential receiver? What is its hysteresis and input sensitivity? | HS receivers must resolve the HS eye (differential amplitude down to the 150 mV squelch region); hysteresis must stay well below that. FS needs 200 mV sensitivity over a 0.8–2.5 V common mode. |
| I6 | Reference frequency | Which reference frequencies must the product support? | Fixed ÷20 = 24 MHz only. Others need a programmable divider in the PLL (control `REFSEL` from the digital). |
| I7 | Reference into the digital | Can a buffered copy of `CDR_FREF` (and a ÷20 feedback copy) be delivered to the digital? | Needed for the digital PLL lock detector (3.4). |
| I8 | Level shifting at 480 Mbit/s | Can the TX accept 1.8 V inputs and the RX deliver 1.8 V outputs, so no HS-rate level shifters are needed outside the blocks? | See 3.5. |
| I9 | `TX_I_5U`, `TX_VREF`, `RX_VREF` | Is `TX_I_5U` a 5 µA bias current input or a logic mode pin? Who generates `TX_VREF`, `RX_VREF` and the 5 µA? | A bias / bandgap block is not in the AFE yet (5.1). If `TX_I_5U` is a logic pin, its meaning and its register bit must be defined. |
| I10 | `TX_CAP_P/N` | External (off-chip) capacitors: needs two extra package pins and pads. Value? Could they be on-chip? | Pin count, pad list (analog pads, not BBSUD8F) and the board design. |
| I11 | Trims | Which parameters need trimming (TX current / amplitude, RX threshold / hysteresis, CDR charge-pump current, VCO band, squelch / disconnect thresholds)? How many bits each? | Defines the trim / enable register map (WORK_PLAN 6.4). |
| I12 | 480 MHz in the digital | Could the TX accept 2- or 4-bit parallel data (240 / 120 MHz) and the CDR deliver 1:2 or 1:4 demultiplexed data? | xh018 is a 180 nm process: digital logic at 480 MHz (2.08 ns) is at its limit. A small serializer / deserializer inside the analog boundary would move the digital to 120–240 MHz (see risk R1). |

---

## 5. What else needs to be developed

### 5.1 Analog blocks still missing (for a USB3320-class PHY)

| Block | Needed for | Key requirements (USB 2.0) |
|---|---|---|
| **HS squelch detector** | HS receive (`hs_squelch`), HS LineState, CDR lock qualification | Squelch when the differential amplitude is below 100 mV, active above 150 mV; fast enough not to eat more SYNC bits than the budget in 3.2. |
| **HS disconnect detector** | Host mode (`host_disc`, sampled during the HS EOP) | Disconnect when the differential amplitude exceeds 525–625 mV. Only needed if host / OTG role is in scope. |
| **FS / LS transmitter** | FS / LS operation, SE0 (reset, EOP), chirp-mode terminations, Test_J / K | Single-ended 3.3 V drivers, 28–44 Ω output impedance (with series resistors), FS rise / fall 4–20 ns, LS 75–300 ns, matched crossover. In the USB3320 the FS drivers driving low also act as the HS 45 Ω terminations. |
| **FS / LS receivers** | `rxrcv`, `rxdp`, `rxdm`, LineState in FS / LS, SE0 detection, chirp detection | Differential receiver (200 mV sensitivity, 0.8–2.5 V common mode), single-ended receivers on DP and DM (thresholds 0.8–2.0 V, with hysteresis). |
| **Terminations and pulls** | Attach, speed signalling, HS termination, host role | Switchable 1.5 kΩ DP pull-up (device), 45 Ω HS terminations to ground (or via the FS drivers), 15 kΩ pull-downs on DP / DM (host / OTG). Controlled by `dp_pullup_en`, `hs_term_en`, `dp/dm_pulldown_en` (WORK_PLAN 3.3). |
| **VBUS comparators / ID detect** | OTG, session detection, VbusState in RXCMDs | `a_vbus_vld` (4.4 V), `sess_vld` (0.8–4.0 V), `sess_end` (0.2–0.8 V), ID pull-up and comparator; VBUS charge / discharge resistors. Can be reduced to `sess_vld` only for a device-only product. |
| **Bias / bandgap** | `TX_VREF`, `RX_VREF`, `TX_I_5U`, comparators, PLL / CDR | Reference voltages and currents, with an external precision resistor (USB3320: RBIAS) to set the HS driver current. |
| **1.8 V regulator + POR / power-good** | Digital and CDR supply from VDD33; reset | `PWR_GOOD` to the power sequencer, a POR for the digital (WORK_PLAN 5.1 / 5.4). |
| **Crystal oscillator / REFCLK buffer** | `CDR_FREF`, digital lock detector | Crystal or external clock input; enable for suspend. |
| **Enables and power-down** | Suspend current (USB: ≤ 2.5 mA for the whole device) | `TX_EN` exists; `RX_EN`, `PLL_EN`, `CDR_EN`, bias / LDO enables are needed so that the HS RX, TX and PLL can be switched off in suspend while the FS/LS receivers stay on for resume detection. |
| **ESD and analog pads** | DP / DM, `TX_CAP_P/N`, RBIAS, XI / XO, VBUS, ID | Analog / HV pads from the X-FAB I/O library; USB pins need high-speed-compatible ESD (low capacitance). |
| **Analog loopback / test bus** | Production test, debug | Near-end TX → RX loopback without a cable; an analog test bus for VREF, VCO control voltages and bias. Controlled by WORK_PLAN 7.2 / 7.3. |

### 5.2 Digital blocks needed for the integration

These extend `WORK_PLAN.md`; the phase numbers in brackets point there.

| Module (proposed) | Function | Work plan |
|---|---|---|
| `usb_afe_tx_if` | Retiming of the TX bit stream into `TX_IN_P/N` (complementary flops), programmable `TX_EN` lead / lag (shift-register delay of the data), HS vs. FS/LS driver select, FS/LS driver controls (`FS_OE`, `FS_DAT`, `FS_SE0`, `FS_LS`), chirp mode, idle clamp. | 6.1, 3.4, 3.5 |
| `usb_afe_rx_if` | Maps the CDR clock / data and the squelch output onto `usb_rx_datapath`; generates `hs_cdr_lock` from a squelch-release delay; RX enable / power-down per speed. | 6.2 |
| `usb_pll_lock_det` | Digital PLL lock / loss-of-lock detector (frequency count of `clk_bit` against the reference), plus a CDR sanity check (`clk_rx` frequency within a window while squelched). | 5.3 |
| `usb_rx_status_sync` | Synchronizers and glitch filters for squelch, disconnect, `rxdp`, `rxdm`, `rxrcv`, VBUS / ID comparators. | 3.1, 4.1 |
| `usb_line_state` | LineState / event detection from the FS/LS receivers and squelch. | 3.2 |
| `usb_mode_term_ctrl` | Termination and pull control, ordered switching. | 3.3 |
| `usb_afe_trim_regs` | Trim / enable register block behind the ULPI vendor registers, with the map from I11. | 6.4, 6.6 |
| `usb_pwr_seq` | Power-up / suspend sequencing of bias, LDO, PLL, CDR, TX, RX, isolation. | 5.4, 5.6 |
| `usb_clk_gen` | `ce60` and `CLKOUT` from `clk_bit`, glitch-free stop for ClockSuspendM, reference divider code from `REFSEL`. | 5.2, 5.3 |
| `usb_phy_ulpi_digital` | New digital top level with the analog-side ports named as in section 3; `usb_ulpi_phy_pads` then wraps it. | 8.1 |

### 5.3 Verification models (digital testbench side)

| Model (proposed) | Behaviour to model |
|---|---|
| `afe_hs_tx_bm` | Differential current driver: output levels (J / K / idle), `TX_EN` settling time, delay, polarity; flags `TX_IN_P` = `TX_IN_N` (skew glitch) longer than a limit. |
| `afe_hs_rx_bm` | Differential receiver with threshold and hysteresis; output delay. |
| `afe_cdr_bm` | Bang-bang CDR: VCO at 480 MHz × (1 + ppm), free-running when there is no data, phase steps per transition, lock after a configurable number of bits, wrong bits before lock, jitter. |
| `afe_squelch_bm`, `afe_fsls_bm`, `afe_term_bm` | Squelch with response delay; FS/LS drivers / receivers with slew delay; termination states. |
| `usb_line_model` | DP / DM with both ends' drivers and terminations, resolving the line voltage (Verilog `real` variables in Icarus), so attach, chirp, SE0 and HS idle can be checked by level. |

Each model is correlated with the analog team's SPICE results: a sign-off table with the simulated value, the model parameter and the corner for every item in section 3 (delays, lock time, hysteresis, settling, levels).

---

## 6. Integration phases

| Phase | Content | Depends on | Done when |
|---|---|---|---|
| **A0 — Interface specification** | Answer I1–I12 with the analog team; freeze the AFE pin list, polarities, timing (setup / hold, delays, lock time), supplies and reset values in an interface spec (`DOC/afe_interface_spec.md`); update the `afe_interface` diagram. | — | Signed-off pin list and timing table; decisions recorded in section 4 and in `WORK_PLAN.md` (D1 confirmed or changed). |
| **A1 — Behavioural models** | The models of 5.3, with parameters from A0; unit TBs per model. | A0 (first draft is enough) | Models reproduce the sign-off table values. |
| **A2 — HS TX integration** | `usb_afe_tx_if`; TB: `usb_tx_path` → `usb_afe_tx_if` → `afe_hs_tx_bm` → line model → reference decoder; lead / lag, idle clamp, polarity, P/N skew check. | A1, WORK_PLAN 6.1 | HS packets decode correctly at the line; `TX_EN` timing matches the spec. |
| **A3 — HS RX integration** | `usb_afe_rx_if`, squelch-based `hs_cdr_lock`; TB: line model → `afe_hs_rx_bm` → `afe_cdr_bm` → `usb_rx_datapath`; shortened SYNC (12 bits), ±1000 ppm, lock-time sweep, squelch timing. | A1, I1, I2 | Every packet with a ≥ 12-bit SYNC is received; the lock-time margin is documented. |
| **A4 — Clocking and lock** | `usb_clk_gen`, `usb_pll_lock_det`, `REFSEL` handling, PLL / CDR enables; TB with a PLL model (lock time, loss of lock, reference frequency error). | A0 (I6, I7), WORK_PLAN 5.2 / 5.3 | Lock / loss of lock detected within spec; `CLKOUT` starts and stops glitch-free. |
| **A5 — FS / LS and line state** | Once the FS/LS analog blocks exist: FS/LS driver controls in `usb_afe_tx_if`, `usb_rx_status_sync`, `usb_line_state`; FS/LS loopback through the models. | 5.1 FS/LS blocks, WORK_PLAN 3.1 / 3.2 | FS/LS packets and LineState correct through the models. |
| **A6 — Terminations, attach and chirp** | `usb_mode_term_ctrl`; attach, reset, HS handshake (chirp K / KJ), HS termination switching, suspend / resume through the line model. | A2, A5, WORK_PLAN 3.3–3.5 | The system TB enumerates at HS (M3 in `WORK_PLAN.md`). |
| **A7 — Power, bias and isolation** | `usb_pwr_seq`, `usb_afe_trim_regs`, isolation / level-shift control; check every boundary signal for its reset value and its isolated value. | A0 (I9, I11), WORK_PLAN 5.4 / 6.4 / 6.5 | Power-up and suspend sequences run in the system TB; no boundary signal is undefined while a domain is off. |
| **A8 — Mixed-signal verification** | Co-simulation of the digital netlist (from `run_synth.sh` or the final netlist) with the transistor-level TX, RX and CDR in the analog team's simulator (e.g. Spectre AMS): HS TX eye at DP / DM against the USB eye template, HS RX → CDR → digital with a pattern generator (amplitude, ppm, jitter), chirp levels, squelch release, suspend / resume. | A2–A7 | Eye-template and receive margins met in all corners. |
| **A9 — Physical integration** | Floorplan (digital, AFE, pads, `TX_CAP` / RBIAS / crystal pins), supply domains (3.3 V analog, 1.8 V CDR, 1.8 V digital), the 480 MHz clock from the PLL into the digital clock tree, routing of the HS P/N pairs, guard rings and substrate noise separation, ESD; boundary timing in the SDC (WORK_PLAN 9.1). | A0, WORK_PLAN 9.1 / 9.3 | Timing closed at 480 MHz (or at the reduced rate from I12); DRC / LVS clean at the boundary. |

### Order

```
A0 ─► A1 ─┬─► A2 (HS TX) ─────────────┐
          ├─► A3 (HS RX + CDR) ───────┤
          ├─► A4 (clocking) ──────────┼─► A6 (attach / chirp) ─► A8 (AMS) ─► A9
          └─► A5 (FS/LS, needs 5.1) ──┘          ▲
                         A7 (power / trims) ──────┘
```

A0 is on the critical path for everything; A2, A3 and A4 can start with draft parameters. A5 and A6 wait for the missing FS/LS analog blocks, which are the largest open item on the analog side.

---

## 7. Milestones

| Milestone | Content | Exit criterion |
|---|---|---|
| **AM1 — Interface frozen** | A0 | Pin list, polarities, timing and supplies agreed; I1–I12 closed. |
| **AM2 — HS loopback through models** | A1–A4 | HS TX → line → HS RX → CDR → digital passes with model parameters from the sign-off table. |
| **AM3 — Full-speed-capable PHY model** | A5–A7 | Attach, HS handshake, HS / FS / LS traffic, suspend / resume in the system TB with all AFE models. |
| **AM4 — AMS sign-off** | A8 | Mixed-signal results within spec in all corners. |
| **AM5 — Integration ready** | A9 | Floorplan, boundary timing and physical checks done. |

---

## 8. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | 480 MHz digital logic in 180 nm (xh018) | Serializer / HS RX front end don't close timing | Run static timing on the bit-rate paths now (OpenSTA with the xh018 Liberty, slow corner). If it fails: move the last 2:1 / 4:1 serialization and the first 1:2 / 1:4 demultiplexing into the analog boundary (I12), and rework `usb_tx_serializer` / `usb_rx_hs_frontend` to the parallel interface. |
| R2 | CDR lock time too long for a 12-bit SYNC | Lost packets behind hubs | Simulate early (I2); tune the bang-bang loop gain; the coarse PLL loop already helps. If needed, lower `HS_ZMIN` and accept a higher false-SYNC risk. |
| R3 | Two ring VCOs that share one control voltage | The CDR VCO free-runs off-frequency if the VCOs mismatch, which lengthens lock | Match the VCOs in layout; check the coarse-tuning error over corners and mismatch (Monte Carlo); the fine loop must cover it within the lock-time budget. |
| R4 | 3.3 V ↔ 1.8 V crossing at 480 Mbit/s | Duty-cycle distortion, P/N skew, closed eye | Keep HS-rate level shifting inside the analog blocks (I8); characterise duty cycle and skew in A8. |
| R5 | FS/LS drivers, receivers, squelch, terminations not designed yet | No enumeration (every device starts at FS), no HS handshake | Start these analog blocks now; they are on the critical path to AM3. |
| R6 | Schmitt-trigger hysteresis on the HS receiver | Small HS eyes are not resolved | Check sensitivity against the HS receive eye template (I5); if needed, use a high-gain comparator without hysteresis for HS and keep the Schmitt receiver for FS/LS. |
| R7 | Fixed ÷20 PLL | Only 24 MHz references work | Decide the supported references (I6) before the PLL layout is frozen. |
| R8 | No lock indicators in the analog blocks | Reset released before the clock is valid; CDR data used before lock | Digital lock detectors (A3, A4); conservative defaults; a register to override them for test. |
| R9 | Behavioural models drift from the transistor-level blocks | The digital passes against wrong models | Correlation table (5.3), re-run after every analog change; AMS runs (A8) as the final check. |
