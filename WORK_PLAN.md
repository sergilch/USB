# Work Plan — Fully Functional Digital Section of the USB 2.0 ULPI PHY

*Based on `usb_phy_ulpi_digital_description.md`, the detailed diagrams in `DOC/Diagramm/` (`usb_phy_ulpi_digital`, `ulpi_interface_controller`, `ulpi_register_file`, `afe_interface`) and the RTL in the repository root as of 2026-11-08. Updated 2026-11-10 for the pad wrapper, the register-access fixes and the follow-ups they raised (Phase 1A).*

---

## 1. Goal and scope

**Goal:** a synthesizable Verilog-2005 digital core that, together with the AFE (developed separately), works as a complete ULPI 1.1 USB 2.0 PHY for HS, FS and LS, modelled on the USB3320. It covers everything inside the blue "DIGITAL CORE" box of the block diagram, plus the digital side of the AFE interface.

**In scope:** ULPI interface controller, TX path, RX path, register file, mode/termination control, HS support logic, OTG/VBUS control, line-state/event detection, clock/reset/power management, the AFE interface (digital part) and DFT hooks.

**Out of scope:** the analog blocks (transmitter, receiver, PLL/CDR, terminations, comparators, regulator), the physical level-shifter and isolation cells (only their control signals are in scope), and the pad cells themselves. The pad *wrapper* (`usb_ulpi_phy_pads`, X-FAB `BBSUD8F` cells) is in scope.

---

## 2. Current state (gap analysis)

### 2.1 Already implemented

These blocks exist in RTL. All 22 testbenches pass with Icarus Verilog.

| Diagram block | RTL module(s) | Status |
|---|---|---|
| ULPI Interface Controller: input capture, TXCMD decoder | `usb_ulpi_input_capture` | Done, unit-tested |
| ULPI Interface Controller: bus-owner FSM, output registers | `usb_ulpi_bus_owner` | Done, unit-tested |
| ULPI Interface Controller: register access FSM | `usb_ulpi_reg_access` | Done; covered by the integration TBs. 2026-11-10: new `rd_pend` output (read acknowledged, data not ready) |
| ULPI Interface Controller: RX data handler, RXCMD generator, output arbiter | `usb_ulpi_rx_handler`, `usb_ulpi_rxcmd_gen`, `usb_ulpi_out_arbiter`, `usb_ulpi_rx_path` | Done; covered by `tb_usb_ulpi_phy_if` |
| Register read data merge | `usb_ulpi_burst_mux` | Done. 2026-11-10 fix: no PHY burst starts while `rd_pend` = 1. Before, a pending RXCMD went out in the read-data cycle, ahead of the register byte. Found by `tb_usb_ulpi_phy_pads` |
| TX Holding Reg / Ctrl | `usb_tx_holding` | Done, unit-tested |
| Bit Stuffer | `usb_bit_stuffer` | Done, unit-tested |
| Serializer 8:1 + EOP Gen | `usb_tx_serializer` | Done, unit-tested |
| ULPI Register File (immediate map 00h–18h, mirrored at extended 00h–3Fh) | `usb_ulpi_reg_file` | Done, unit-tested. 2026-11-10 fix: extended 00h–3Fh now reach the immediate registers (ULPI 1.1 §4); before, they read 00h and ignored writes. It is the only register file in the design (`u_core.u_rf`) |
| SYNC + PID/Data Mux | `usb_tx_sync_mux` | Done, unit-tested (added 2026-11-08) |
| NRZI Encoder | `usb_nrzi_encoder` | Done, unit-tested (added 2026-11-08) |
| TX path wrapper (stuffer → NRZI → serializer, underrun discard) | `usb_tx_path` | Done, unit-tested (added 2026-11-08) |
| RX front ends (HS capture on the recovered clock, FS/LS DPLL) | `usb_rx_hs_frontend`, `usb_rx_fsls_frontend` | Done, unit-tested (added 2026-11-08) |
| NRZI Decoder, SYNC Detect, Bit Unstuffer, Deserializer 1:8, EOP + RxError Check | `usb_rx_nrzi_decoder`, `usb_rx_sync_detect`, `usb_rx_bit_unstuffer`, `usb_rx_deserializer`, `usb_rx_eop_check`, wrapper `usb_rx_decoder` | Done, unit-tested (added 2026-11-08) |
| Elastic Buffer (CDC) | `usb_rx_elastic_buffer` | Done, unit-tested (added 2026-11-08) |
| RX datapath wrapper | `usb_rx_datapath` | Done; `tb_usb_rx_datapath` (TX → RX loopback) passes |
| Interconnect | `usb_tx_datapath`, `usb_ulpi_core`, `usb_ulpi_phy_if`, `usb_ulpi_phy_top` | Done; `tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core`, `tb_usb_ulpi_phy_if` pass |
| Pad wrapper (BBSUD8F for CLK, DATA, DIR, NXT, STP, RESETB; protection pulls; RESETB synchronizer; NAND tree) | `usb_ulpi_phy_pads` | Done; `tb_usb_ulpi_phy_pads` (register access at the pins) passes (added 2026-11-10) |

### 2.2 Missing or incomplete

| Diagram block | What is missing |
|---|---|
| RX datapath integration | `usb_rx_datapath` (done, see 2.1) is not instantiated in `usb_ulpi_phy_top` yet, which still takes `rx_*` as top-level ports. Planned for Phase 8.1. |
| Line State / Event Detector | Not implemented. `linestate` and `host_disc` are top-level inputs. |
| Mode / Termination Control | Not implemented. XcvrSelect / TermSelect / OpMode are only exported; there are no pull-up, termination or pull-down outputs. OpMode `01`/`11` have no effect. |
| HS Handshake / Chirp support | Not implemented. `sync_dis` is tied to `0` in `usb_ulpi_phy_top`. |
| OTG / VBUS Control | Not implemented. `otg_ctrl` is exported raw; VBUS/ID status are top-level inputs with no filtering. |
| Clock / Reset / Power Mgmt | Not implemented. `ce60` and `rst_n` are top-level inputs; `soft_reset`, `suspendm` and `dir_hold` have no logic. |
| ULPI low-power mode | Not implemented: SuspendM entry, LineState on DATA[1:0] while DIR is held, wake-up via STP or a bus event, ClockSuspendM, AutoResume. |
| AFE Interface (digital) | Not implemented: TX retiming, RX capture, receiver status sync and glitch filter, termination output ordering, PLL/CDR control, power sequencer, trim/enable registers. |
| DFT / Test Modes | Not implemented: loopback, analog test mux control, scan and BIST hooks. |
| Register file extras | Extended 40h–FFh read 00h; Carkit (19h–1Fh) and vendor/trim registers (30h–3Fh) are not implemented; Interface Control bits are stored but have no effect. |
| Top level | There is no `usb_phy_ulpi_digital` top level that ties the PHY core to the AFE interface. `usb_ulpi_phy_pads` currently wraps `usb_ulpi_phy_top` only. |
| ULPI register read timing | The PHY raises DIR 2–3 ticks after the NXT that acknowledges a RegRead (reg_access RREQ → RWAIT → RRET). ULPI 1.1 Figure 22 shows DIR in the very next cycle. Links that wait for DIR work; Links with fixed timing do not (D7). |
| ULPI holding state | Not implemented (ULPI 1.1 §3.12): STP unexpectedly high → do not interpret DATA, do not raise DIR, send one merged RXCMD when leaving. The STP pull-up and DATA pull-downs exist in `usb_ulpi_phy_pads`. |
| Pad wrapper | The pull pin polarity of BBSUD8F (pull-up at PUEN = 0, pull-down at PUEN = 1 / PDEN = 0) comes from the simulation model only, not checked against the X-FAB datasheet (D8). The output cells are not switched to input mode for the NAND-tree test. RESETB has no pull. The X-FAB files (`BBSUD8F.v`, `VLG_PRIMITIVES.v`, `IO_CELLS_JIF3V.v`) are not in the public repo, so `tb_usb_ulpi_phy_pads` only runs where a local PDK copy exists. |
| Testbench gap | `tb_usb_ulpi_core` did not catch the RXCMD-before-read-data bug. Its Link model finds the read data through internal signals and does not treat the first byte after the turnaround as the read data. |

---

## 3. Discrepancies to resolve first

Some points in the description don't match the RTL or the ULPI/UTMI+ model. They need a decision before the matching work packages start.

| # | Topic | Description says | RTL / standard | Recommendation |
|---|---|---|---|---|
| D1 | **Clocking** | Two clock domains: `clk60` and `clk_bit` "recovered by the CDR". | All RTL runs on one clock, the PLL `clk_bit` (480 MHz), with `ce60` as the 60 MHz enable. | Keep the single PLL clock for the core and the TX path. Treat the CDR-recovered clock as a third, RX-only domain that ends at the elastic buffer, whose read side is `clk_bit` + `ce60`. Confirm with the analog team what the CDR actually delivers: a recovered clock plus data, or oversampled data on the PLL clock. |
| D2 | **FS/LS receive** | The CDR recovers `clk_bit` at 480 / 12 / 1.5 Mbps. | FS/LS usually doesn't use the HS CDR. | Recover FS/LS data digitally: oversample `rxrcv` / `rxdp` / `rxdm` on `clk_bit` (40× for FS, 320× for LS) with a small DPLL. This needs no analog support and reuses the `FS_DIV` / `LS_DIV` parameters. |
| D3 | **HS chirp FSM** | The PHY has an "HS Handshake / Chirp FSM" (chirp-K, KJ detection, reset, suspend/resume). | In ULPI/UTMI+ the **Link** runs the HS handshake. It uses OpMode `10` + TXCMD NOPID with 00h data to send chirps and watches LineState in RXCMDs. | Implement the PHY-side support, not an autonomous FSM: chirp transmission without SYNC/EOP/stuffing/NRZI, correct LineState in chirp and HS modes, and HS disconnect sampling. An autonomous FSM is only needed if the Link is a custom controller that expects it. |
| D4 | **OpMode 10 framing** | NRZI is "bypassed in chirp and test modes". | The RTL bypasses stuffing and NRZI but still sends SYNC and EOP (`sync_dis` = 0, no EOP-suppress input on the serializer). | Check ULPI 1.1 / UTMI+ for what is sent in OpMode `10`, then drive `sync_dis` and an EOP-suppress control from Mode Control. |
| D5 | **Carkit / serial modes** | The register map lists the Interface Control bits FsLsSerialMode 6-pin / 3-pin, CarkitMode and Indicator*. | Stored, no effect. | Declare them out of scope for the first release: readable and writable, no effect, documented. Add them later if a target Link needs serial mode. |
| D6 | **"idle 00h" output** | The arbiter priority list ends with "4) idle 00h". | `usb_ulpi_out_arbiter` ends the burst instead (DIR falls); ULPI has no idle byte while DIR = 1. | Keep the RTL behaviour and update the diagram text. |
| D7 | **Register read timing** | ULPI 1.1 Figure 22: DIR rises in the cycle after the NXT that acknowledges RegRead, and the data follows in the next cycle. | DIR rises only once the register file has answered, 2–3 ticks after NXT. | Make the read path fixed-latency: answer the register file combinationally or in the same tick, take the bus right after the acknowledge, and return the data in the next tick. Check against the USB3320 datasheet timing, then make the Link models strict (Phase 1A). |
| D8 | **BBSUD8F pull control** | — | The model pulls up at PUEN = 0 and pulls down at PUEN = 1, PDEN = 0. That polarity is unusual for a pin named "enable". | Confirm it in the X-FAB IO_CELLS_JIF3V datasheet before tape-out. If the model is wrong, invert `stp_puen` / `data_pden` in `usb_ulpi_phy_pads`. |

---

## 4. Work packages

Each package lists its deliverables, dependencies and "done" criteria. Every new module follows the repository conventions: Verilog-2005, a spec in the header comment, `clk_bit` + `ce60` (`ce`), active-low async `rst_n`, and a self-checking testbench `tb_<module>.v` with an `errors` counter, the `TEST PASSED` / `TEST FAILED` line, a watchdog and a VCD dump.

Size: **S** ≈ one small module + testbench, **M** ≈ a few modules or one complex FSM, **L** ≈ a subsystem.

### Phase 0 — Infrastructure (S)

| ID | Task |
|---|---|
| 0.1 | Add a `Makefile` (or `run_tests.sh`) with one target per testbench, using the file lists from the TB headers. A `make test` target runs everything and summarises the `TEST PASSED` / `FAILED` lines. Build `tb_usb_ulpi_phy_pads` with `-DDISPLAY_PD_PU_EN`, and skip it with a clear message if the local X-FAB files are missing. |
| 0.2 | Add a lint step: `verilator --lint-only -Wall` on every RTL file (Verilator is installed now). Clean up the warnings that already exist: WIDTHEXPAND in `usb_ulpi_rx_handler` and `usb_ulpi_reg_access`, and UNOPTFLAT on `rdy` in `usb_ulpi_bus_owner`. Leave the vendor pad model out of the lint. |
| 0.3 | Add a synthesis smoke test (`yosys` `synth` per top level) to catch non-synthesizable code and inferred latches. |
| 0.4 | Optional: GitHub Actions workflow that runs 0.1–0.3 on every push. |

**Done when:** the six existing unit TBs pass via `make test`, and lint and synthesis run without errors.

### Phase 1 — Complete the TX path (M) — ✅ done 2026-11-08 (except 0.x infrastructure)

| ID | Task |
|---|---|
| 1.1 | **`usb_tx_sync_mux`**: SYNC generation per speed (HS: 32-bit SYNC, FS/LS: 8-bit SYNC, both in pre-NRZI data bits), the PID byte `{~PID, PID}`, NOPID pass-through, header-only packets (`hdr_empty`), and `sync_dis`. Ports as instantiated in `usb_tx_datapath.v`. |
| 1.2 | **`usb_nrzi_encoder`**: NRZI (0 = transition, starting from J = 1), passes `nbits` / `last` through, `bypass_en` pass-through, reset to J at each packet. |
| 1.3 | **`usb_tx_path`**: `usb_bit_stuffer` → `usb_nrzi_encoder` → `usb_tx_serializer`, ports as in `usb_tx_datapath.v`. `bypass_en` drives `stuff_dis` and the NRZI bypass. |
| 1.4 | Unit TBs for 1.1 and 1.2. |
| 1.5 | Build and pass the existing integration TBs `tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core` and `tb_usb_ulpi_phy_if`. |

**Done when:** all nine existing testbenches pass.

### Phase 1A — ULPI interface follow-ups (S–M)

Raised by `tb_usb_ulpi_phy_pads` (2026-11-10). They depend on nothing else and can start now.

| # | Deliverable |
|---|---|
| 1A.1 | **Fixed-latency register read** (D7): DIR in the cycle after the RegRead acknowledge, data in the next cycle. Keep the `rd_pend` interlock and the existing TX / register interlocks. |
| 1A.2 | **Strict Link models**: in `tb_usb_ulpi_core`, `tb_usb_ulpi_phy_if` and `tb_usb_ulpi_phy_pads`, the read data is the first byte after the turnaround, taken from the pins only. After 1A.1, also check the Figure 22 timing. |
| 1A.3 | **ULPI holding state** (§3.12): STP high while the PHY does not expect it → ignore DATA, keep DIR low, collect RXCMD changes into one RXCMD after leaving. Add a TB case in which the Link tri-states its outputs and the pad pulls hold STP high. |
| 1A.4 | **Pad wrapper review**: confirm the BBSUD8F pull polarity (D8), decide on a RESETB pull, and confirm the DATA pull-down condition (now: protection on and PHY not driving) against the USB3320. |

**Done when:** all TBs pass with the strict Link models, and D7 / D8 are closed.

### Phase 2 — RX datapath (L) — ✅ done 2026-11-08

Decisions D1 and D2 were taken as recommended, as working assumptions to be confirmed with the analog team: the HS bit chain runs on the CDR's recovered clock `clk_rx` (the CDR is assumed to free-run while there is no signal), and FS/LS data is recovered by a DPLL on `clk_bit`. Only `usb_rx_hs_frontend` depends on D1. Deviation from the diagram: SYNC detection is a separate stage between the NRZI decoder and the unstuffer (`usb_rx_sync_detect`), because the unstuffer must know where SYNC ends. The HS receiver only rearms SYNC detection when it goes inactive (squelch), so packets need an idle gap long enough for the squelch detector. Not done from the list below: babble detection.

The chain from the diagram, with the interface to `usb_ulpi_rx_path` that already exists (`rx_start`, `rx_valid`/`rx_data`, `rx_end`, `rx_error`).

| ID | Task |
|---|---|
| 2.1 | **RX front end / capture**: HS: capture the CDR data on the recovered clock, gated by CDR lock and squelch. FS/LS: oversampling DPLL on `clk_bit` with edge-based bit-centre tracking (decision D2). |
| 2.2 | **SYNC detect + deserializer 1:8**: HS SYNC with a tolerance for bits lost at the start (the squelch/CDR lock eats some leading SYNC bits); FS/LS `KJKJKJKK`; byte alignment; LSB first. |
| 2.3 | **NRZI decoder**. |
| 2.4 | **Bit unstuffer**: removes the 0 after six 1s; a seventh 1 is a stuff error (in HS it also marks the EOP). |
| 2.5 | **EOP detect + RxError check**: HS EOP (bit-stuff violation / squelch), FS/LS EOP (SE0 ≥ 1 bit, then J), a non-integral byte count at EOP, a missing EOP and babble timeout → `rx_error`. |
| 2.6 | **Elastic buffer (CDC)**: recovered-clock write side, `clk_bit` + `ce60` read side, Gray-coded pointers, sized for the worst-case ±500 ppm drift over a maximum-length packet, plus overflow/underflow → `rx_error`. For FS/LS (already on `clk_bit`) it reduces to a bypass or a simple FIFO. |
| 2.7 | **`usb_rx_datapath`** wrapper that connects 2.1–2.6 to `usb_ulpi_rx_path`, with RX disabled while the PHY transmits. |
| 2.8 | Unit TBs for each block, plus a **TX → RX digital loopback** test: random packets through `usb_tx_path` → line model (jitter, ppm offset, lost leading SYNC bits) → RX datapath, and compare the bytes. |

**Done when:** loopback passes for HS/FS/LS over random lengths and data, including the 6-ones corner cases and injected stuff/EOP errors.

### Phase 3 — Line state, mode and termination control (M)

| ID | Task |
|---|---|
| 3.1 | **Receiver status sync + glitch filter** (AFE interface): 2-FF sync of `rxdp`, `rxdm`, `rxrcv`; sync + N-cycle programmable filter for `squelch` and `disc`. |
| 3.2 | **Line State / Event Detector**: FS/LS LineState = `{DM, DP}` (SE0 / J / K / SE1); in HS mode LineState comes from squelch (`!squelch` → J, squelch → SE0); chirp-mode qualification; HostDisconnect from `disc` (sampled during the HS EOP in host mode). Replaces the `linestate` / `host_disc` top-level inputs. |
| 3.3 | **Mode / Termination Control**: decode XcvrSelect / TermSelect / OpMode / OTG pull-down bits into `dp_pullup_en`, `hs_term_en`, `dp_pulldown_en`, `dm_pulldown_en`, using the UTMI+/ULPI termination table (device and host roles). OpMode `01` = driver disabled; `11` handled per ULPI 1.1 (check what the spec defines for it). Switches on a `ce60` edge, in a fixed order (HS termination off before pull-up on), all off in reset/isolation. |
| 3.4 | **TX control from Mode Control**: `sync_dis` and EOP suppression for OpMode `10` (decision D4), TX disabled for OpMode `01`, and HS vs. FS/LS driver mode on `tx_speed`. |
| 3.5 | **HS support (decision D3)**: chirp-K / chirp-J transmission through OpMode `10` with 00h data, LineState behaviour during chirp, and resume / remote-wakeup K signalling through the same path. |
| 3.6 | Unit TBs, plus integration scenarios: device attach (pull-up on), HS handshake driven by a Link model (chirp K, host KJ chirps → switch to HS termination), suspend/resume K, reset SE0. |

**Done when:** a Link model can run a complete device attach → HS handshake → HS traffic sequence against the core with an AFE line model.

### Phase 4 — OTG / VBUS control (S)

| ID | Task |
|---|---|
| 4.1 | **VBUS / ID interface**: 2-FF sync + filter (optional ms-range debounce) for `a_vbus_vld`, `sess_vld`, `sess_end`, `id_gnd`; registered control outputs `id_pullup`, `drvvbus`, `chrg_vbus`, `dischrg_vbus` from OTG Control. |
| 4.2 | ID sampling with `IdPullup` (only sample ID while the pull-up is on, with a settling delay); `DrvVbusExternal` / `UseExternalVbusIndicator` handling, or document them as not supported. |
| 4.3 | Move the VbusState mapping out of `usb_ulpi_phy_top` into this block. |
| 4.4 | Unit TB: RXCMD and interrupt-latch behaviour on VBUS/ID changes, through the existing IE masks. |

### Phase 5 — Clock, reset, power and low-power mode (L)

| ID | Task |
|---|---|
| 5.1 | **Reset synchronizers**: `RESETB` / POR → `rst_n` per domain (`clk_bit`, recovered clock), async assert / sync release, held until `pll_lock` and `pwr_good`. The `clk_bit` synchronizer for the RESETB pin already exists in `usb_ulpi_phy_pads` (`core_rst_n`); POR, `pll_lock`, `pwr_good` and the recovered-clock domain are still open. |
| 5.2 | **`ce60` generator**: divide `clk_bit` by 8, phase-aligned with the `clk60` the PLL sends to `CLKOUT`. It is currently a top-level input. |
| 5.3 | **PLL / CDR control**: `refsel[1:0]` → divider code (19.2 / 24 / 26 MHz), `pll_en` / `cdr_en` sequencing, lock sync + lock filter, loss-of-lock flag. |
| 5.4 | **Power sequencer**: `pwr_good` → `bias_en` → `pll_en` → wait for lock → release reset → `iso_en` off; suspend sequence (TX, HS RX and PLL off; FS/LS receiver, squelch and resume detect stay on). |
| 5.5 | **`soft_reset`** (Function Control Reset bit): reset the core datapath and the ULPI state machines without clearing the register file (check this against ULPI 1.1). |
| 5.6 | **ULPI low-power mode controller**: SuspendM = 0 → finish the current transfer, hold DIR high (`dir_hold`), drive LineState on DATA[1:0] and the interrupt on DATA[3] (check the pin mapping in ULPI 1.1), stop `CLKOUT` if ClockSuspendM = 0, keep the register file contents. Wake-up when the Link asserts STP or on a bus event (resume K, reset SE0, VBUS/ID change), restart the PLL, wait for lock, drop DIR, send an RXCMD. AutoResume handling. |
| 5.7 | TBs: power-up sequence, soft reset in the middle of a packet, suspend → resume (Link-initiated and host-initiated), clock stop/restart. |

### Phase 6 — AFE interface, digital part (M)

| ID | Task |
|---|---|
| 6.1 | **TX data boundary**: retiming flops for `txd`, `tx_en`, `tx_se0`, driver-mode decode from `tx_speed`, clamped to idle when TX is disabled or isolated. |
| 6.2 | **RX data capture / clock buffer**: capture flops for `rxd` on the recovered clock, data gated until CDR lock (`rx_valid_lock`). |
| 6.3 | **Termination / pull outputs**: output registers for the Phase 3 controls, safe reset defaults. |
| 6.4 | **Trim / enable register block**: a config-bus slave reached through the ULPI extended or vendor register map (e.g. 30h–3Fh or the extended map via 2Fh). Holds trims for HS driver current, HS termination, squelch/disconnect thresholds, VBUS comparator thresholds, PLL/CDR bias and LDO; uses shadow registers with an update strobe and safe reset defaults. The register map must be agreed with the analog team. |
| 6.5 | **Isolation / level-shift control**: `iso_en` / `ls_en` driven by the power sequencer. |
| 6.6 | Extend `usb_ulpi_reg_file` with the vendor/extended registers from 6.4 and update its TB. |

### Phase 7 — DFT and test modes (S–M)

| ID | Task |
|---|---|
| 7.1 | **USB-IF test modes** (Test_J, Test_K, Test_SE0_NAK, Test_Packet): in ULPI the Link drives these with OpMode and TXCMDs. Verify the PHY transmits them correctly (Test_Packet = the full 53-byte pattern from USB 2.0 §7.1.20). |
| 7.2 | **Digital loopback**: TX → RX in the AFE interface, bypassing the analog blocks, selected by a vendor register. |
| 7.3 | **Analog test mux control** (`atb_sel`) and scan isolation at the boundary. |
| 7.4 | Scan readiness: no async logic apart from reset, a test-mode override for internal clock gates and generated resets, and a documented scan-mode port. |
| 7.5 | Optional BIST: PRBS packet generator / checker over the loopback path. |
| 7.6 | **NAND-tree test mode** for the pads: switch all BBSUD8F cells to input mode (EN = 1) under a test-mode input and bring `nand_tree_out` to a test pin or the test mux. Add a TB that toggles every pad pin and checks the chain. The chain already exists in `usb_ulpi_phy_pads`. |

### Phase 8 — Top level and system verification (L)

| ID | Task |
|---|---|
| 8.1 | **`usb_phy_ulpi_digital`** top level: `usb_ulpi_phy_top` + RX datapath + line state + mode/termination + OTG + clock/reset/power + AFE interface + DFT, with the analog-side ports named as in the `afe_interface` diagram (`TXD_A`, `RXD_A`, `PLL_EN`, …). Retire `usb_ulpi_tx_top` or keep it only for its TB. `usb_ulpi_phy_pads` then wraps this top level instead of `usb_ulpi_phy_top`, and `tb_usb_ulpi_phy_pads` moves along with it. |
| 8.2 | **System testbench**: ULPI Link model (extended from the existing one with RX, chirp, suspend), an AFE behavioural model (driver/receiver, squelch, CDR with jitter and ppm offset, comparators), and a USB host/device line model at DP/DM. |
| 8.3 | Scenarios: power-up; register access; device attach and HS handshake; bulk-style HS/FS/LS TX and RX at full rate; back-to-back packets with minimum inter-packet gap; RX overrun; Link STP abort; TX underrun; suspend/resume and remote wakeup; reset; disconnect; OTG session and ID change; all test modes; soft reset. |
| 8.4 | Protocol checkers: ULPI timing (turnaround, NXT/DIR rules, RXCMD on every change) and USB line encoding (SYNC, stuffing, EOP, inter-packet gaps) as assertions in the TBs. |
| 8.5 | Optional interoperability check: run the RTL on an FPGA with an external ULPI Link (e.g. a soft USB controller), using a simple FPGA transceiver model for FS/LS. |

### Phase 9 — Implementation readiness and documentation (M)

| ID | Task |
|---|---|
| 9.1 | Timing constraints (SDC): `clk_bit` 480 MHz, `ce60` multicycle paths (8 cycles), recovered RX clock, false paths through the synchronizers, ULPI output timing relative to `CLKOUT`, including the BBSUD8F pad delays. The core samples the ULPI inputs on the `clk_bit` edge about 1 ns after the CLKOUT edge (as modelled in `tb_usb_ulpi_phy_pads`), so the Link hold time must cover that offset; check it against the ULPI 1.1 / USB3320 I/O timing. |
| 9.2 | CDC review of every crossing (elastic buffer, status synchronizers, reset synchronizers), with a CDC tool if available. |
| 9.3 | Synthesis to the target library: 480 MHz timing closure on the bit-rate paths (serializer, stuffer, RX front end), area and power. |
| 9.4 | Update the module header specs, `CLAUDE.md`, `README.md` and `usb_phy_ulpi_digital_description.md` (decisions D1–D6, final hierarchy); interface spec for the analog team (signal list, timing, reset values). |

---

## 5. Order and dependencies

```
Phase 0 ─┐
         ├─► Phase 1 (TX complete) ─► Phase 2 (RX) ─┐
         │                                          ├─► Phase 8 (top + system TB) ─► Phase 9
         ├─► Phase 3 (line state / mode) ───────────┤
         ├─► Phase 4 (OTG / VBUS) ──────────────────┤
         ├─► Phase 5 (clock / reset / power) ───────┤
         └─► Phase 6 (AFE interface) ─► Phase 7 ────┘
```

- **Phase 1A** has no dependencies. Do 1A.1 / 1A.2 before the system TB (8.2) so that its Link model can be strict from the start.
- **Critical path:** Phase 1 → Phase 2 → Phase 8. Phase 1 comes first because it unblocks the three integration TBs that already exist.
- Phases 3–6 depend only on Phase 0 and the existing register file, so they can run in parallel with Phase 2.
- Decisions **D1/D2** are needed before Phase 2.1/2.6; **D3/D4** before Phase 3.4/3.5; the trim register map (6.4) needs input from the analog team.

## 6. Milestones

| Milestone | Content | Exit criterion |
|---|---|---|
| **M1 — TX complete** | Phases 0 + 1 | All TBs pass via `make test`; lint clean. Phase 1 done: all twelve TBs pass; Phase 0 still open. |
| **M2 — Data loopback** | Phase 2 | TX → RX loopback passes for HS/FS/LS with jitter, ppm offset and injected errors. ✅ Reached 2026-11-08 (`tb_usb_rx_datapath`; ppm offset, lost SYNC bits, D+/D− skew and injected errors; bit-level jitter is left to the analog CDR). |
| **M3 — Enumerable PHY** | Phases 3 + 4 + core of 5 (reset, `ce60`, soft reset) | The system TB runs attach → HS handshake → HS traffic → reset. |
| **M4 — Feature complete** | Rest of Phase 5, Phases 6 + 7 + 8.1 | Low-power mode, test modes, trim registers and the full top level, verified in the system TB. |
| **M5 — Implementation ready** | Phase 8 complete + Phase 9 | All scenarios pass; constraints, CDC review and synthesis results done; documentation updated. |

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The CDR output format is not defined yet (D1) | Rework of the RX front end and elastic buffer | Agree on the interface with the analog team before Phase 2; keep the RX front end a separate, swappable module. |
| 480 MHz timing on the serializer / stuffer / RX front end | Synthesis fails at the target node | Keep bit-rate logic minimal (the existing serializer is already structured this way); check timing early in Phase 0.3 with the target library. |
| Ambiguous ULPI 1.1 / UTMI+ details (OpMode `10`/`11` framing, low-power pin mapping, soft-reset scope) | Wrong behaviour with real Links | Check every point against the ULPI 1.1 spec and the USB3320 datasheet in `DOC/`; record each decision in the module header. |
| Link model and DUT built from the same interpretation of the spec | Shared misunderstanding passes the tests | Cross-check against the USB3320 datasheet waveforms; FPGA test with a real Link core (8.5). |
| X-FAB PDK files are confidential and the repository is public | The pad TB can't run in CI or on clones without the PDK; files could be published by accident | Keep `BBSUD8F.v`, `VLG_PRIMITIVES.v` and `IO_CELLS_JIF3V.v` in `.gitignore`; run the pad TB locally (or on a private CI runner with the PDK); never force-add them. |
| Icarus Verilog limits (no SystemVerilog assertions or coverage) | Weaker verification | Keep Verilog-2005 checkers in the TBs; optionally add Verilator for speed and lint. |
