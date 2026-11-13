# Transceiver — `afe_transceiver` (`AFE/veriloga/afe_transceiver.va`)

*Idealized model of everything that drives or loads DP / DM: the HS current driver (the analog team's HS TX block), the FS / LS transceiver, and the switchable terminations and pulls. Status: written 2026-11-11, not simulated yet (see `AFE/README.md`).*

*Transistor-level design of the same block (180 nm): [transceiver_schematic.md](transceiver_schematic.md).*

| Module | Block | Verilog model with the same behaviour |
|---|---|---|
| `afe_hs_tx` | HS transmitter (existing analog block) | `afe_hs_tx_bm.v` |
| `afe_fsls_xcvr` | FS / LS drivers and receivers (missing, plan 5.1) | `afe_fsls_bm.v` |
| `afe_term` | 1.5 kΩ pull-up, 45 Ω HS terminations, 15 kΩ pull-downs (missing) | `afe_term_bm.v` |
| `afe_transceiver` | All three on one DP / DM pair, with the main parameters passed through | — |

The HS receiver and squelch are in `afe_receiver` ([receiver.md](receiver.md)).

## `afe_hs_tx`: HS current-mode driver

- **Current steering:** `i_hs` · `i_scale` (17.78 mA) flows from `TX_VDD` into `TX_OUT_P` (DP) for `TX_IN_P` = 1 / `TX_IN_N` = 0 (J, polarity Q3), and into `TX_OUT_N` (DM) for 0 / 1. Into the two 45 Ω terminations of an HS link this gives 17.78 mA · 22.5 Ω = **400 mV** (USB 2.0: 360–440 mV, the analog block's figure). Into one 45 Ω (chirp, far end in SE0) it gives about **800 mV**. The current falls off smoothly when an output comes within `v_compl` of `TX_VDD`.
- **`TX_EN` settling:** the current reaches the outputs only `t_en` (20 ns) after `TX_EN` rose, and only if `TX_EN` stayed high. While `TX_EN` = 0 the current is dumped internally and the outputs are high impedance (`r_out`, `c_out`). This is the behaviour `usb_afe_tx_if` was sized for: `TX_EN` leads the data by `tx_lead` bit times, and the default `tx_lead` = ⌈`t_en` / 2.083 ns⌉ = 10 loses no SYNC bit (spec 4.1, A2 result). Q4 asks the analog team for the real `t_en`.
- **Data path:** delay `t_dly` (0.5 ns) from `TX_IN` to the output, linear edges of `t_rf_hs` (0.625 ns, 0–100 %, which is the USB minimum of 500 ps for 10–90 %).
- **P/N check:** `TX_IN_P` = `TX_IN_N` while the driver is settled splits the current half / half, so there is no differential signal. If that lasts longer than `t_skew_max` (0.1 ns), the model prints a message and counts it in `skew_err`. `usb_afe_tx_if` drives P and N from two flops on the same edge, so this only fires on a real boundary skew or glitch.
- **Bias** (Q9, meaning of `TX_I_5U` / `TX_VREF` still open):

| `bias_mode` | `i_hs` scaled by | `TX_I_5U` pin | `TX_VREF` pin |
|---|---|---|---|
| 0 (default) | 1 (ideal) | 1 GΩ to `TX_GND` | 1 GΩ to `TX_GND` |
| 1 | V(`TX_VREF`) / `vref_nom` (1.2 V) | 1 GΩ | sensed |
| 2 | current into `TX_I_5U` / 5 µA | held at `v_i5u` (0.6 V), current sensed | 1 GΩ |

- **`TX_CAP_P/N`** (Q10): connected to the outputs through `r_cap`. The default 1 TΩ means no effect. The pins exist so that the netlist matches the analog block.

## `afe_fsls_xcvr`: FS / LS transceiver

USB 1.1-style interface, as used by `usb_afe_tx_if` and `usb_rx_fsls_frontend`:

| Input state | DP / DM driven to |
|---|---|
| `FS_OE_A` = 0 | off (high impedance) |
| `FS_SE0_A` = 1 | 0 / 0 (SE0; also the 45 Ω host termination during reset / chirp) |
| `FS_DAT_A` = 1, `FS_LS_A` = 0 | VDD33 / 0 (FS J) |
| `FS_DAT_A` = 0, `FS_LS_A` = 0 | 0 / VDD33 (FS K) |
| `FS_DAT_A` = 1, `FS_LS_A` = 1 | 0 / VDD33 (LS J) |
| `FS_DAT_A` = 0, `FS_LS_A` = 1 | VDD33 / 0 (LS K) |

- **Driver:** a voltage source per wire behind `r_out` (45 Ω: 28–44 Ω driver plus series resistor). Linear ramps of `t_fs` = 12.5 ns (10 ns for 10–90 %, USB FS: 4–20 ns) or `t_ls` = 187.5 ns (150 ns, LS: 75–300 ns).
- **Receivers** (delay `t_rx` = 2 ns, outputs 0 / VDD18):
  - `RXDP_A`, `RXDM_A`: single-ended, threshold `vse` = 1.4 V ± `hys_se` / 2 (USB: low < 0.8 V, high > 2.0 V).
  - `RXRCV_A`: differential, 1 above +`vdi` / 2 and 0 below −`vdi` / 2 (USB sensitivity 200 mV).
  - `FS_RX_EN_A` = 0 or VDD33 low: `RXDP_A` = `RXDM_A` = 0, `RXRCV_A` = 1 (isolated values, spec 3.4). `FS_RX_EN_A` is a new pin. The FS/LS receivers stay on in suspend for resume detection (spec 5), so the power sequencer normally keeps it high.
- The digital samples these outputs asynchronously (2-FF synchronizers and DPLL on `clk_bit`), so no setup / hold applies. It needs D+ / D− skew below 5 ns (spec 4.4). In the model both receivers have the same delay.

## `afe_term`: terminations and pulls

| Pin | Element | Use |
|---|---|---|
| `DP_PULLUP_EN_A` | `r_pu` = 1.5 kΩ from DP to VDD33 | FS device attach, chirp |
| `HS_TERM_EN_A` | `r_hs` = 45 Ω from DP and from DM to GND | HS termination. In the USB3320 the FS drivers in SE0 do this; either way works with the model |
| `PD_EN_A0` | `r_pd` = 15 kΩ from DP to GND | host / OTG |
| `PD_EN_A1` | `r_pd` from DM to GND | host / OTG |

`r_sw` adds a switch on-resistance and `t_sw` sets the switching time. There is no DM pull-up: an LS device role is not in the spec (`afe_term_bm` has one for testbenches).

## Pins of `afe_transceiver`

| Pin | Dir | Digital signal (`usb_afe_tx_if` unless noted) |
|---|---|---|
| `TX_IN_P`, `TX_IN_N` | in | `hs_tx_p`, `hs_tx_n` |
| `TX_EN` | in | `hs_tx_en` |
| `TX_I_5U`, `TX_VREF` | in | — (bias block, Q9) |
| `TX_CAP_P`, `TX_CAP_N` | inout | — (external capacitors, Q10) |
| `FS_OE_A`, `FS_DAT_A`, `FS_SE0_A`, `FS_LS_A` | in | `fs_oe`, `fs_dat`, `fs_se0`, `fs_ls` |
| `FS_RX_EN_A` | in | — (power sequencer, new) |
| `RXRCV_A`, `RXDP_A`, `RXDM_A` | out | `rxrcv`, `rxdp`, `rxdm` of `usb_rx_datapath` |
| `DP_PULLUP_EN_A`, `HS_TERM_EN_A`, `PD_EN_A0`, `PD_EN_A1` | in | `dp_pullup_en`, `hs_term_en`, `dp_pulldown_en`, `dm_pulldown_en` (future `usb_mode_term_ctrl`) |
| `DP`, `DM` | inout | USB line (through the ESD pads) |
| `VDD33`, `VDD18`, `GND` | supply | 3.3 V line supply, 1.8 V logic supply of the receiver outputs |

Wrapper parameters: `i_hs`, `i_scale`, `t_en`, `t_dly`, `bias_mode` (HS TX), `t_fs`, `t_ls`, `r_fs_out` (FS/LS). To change any other parameter, instantiate the sub-modules directly.

## Parameters of `afe_hs_tx`

| Parameter | Default | Meaning |
|---|---|---|
| `i_hs`, `i_scale` | 17.78 mA, 1.0 | Driver current, amplitude trim (`TX_AMP`, spec 6) |
| `t_en` | 20 ns | `TX_EN` → current settled |
| `t_dly`, `t_rf_hs` | 0.5 ns, 0.625 ns | Delay, edge time |
| `t_skew_max` | 0.1 ns | Longest tolerated `TX_IN_P` = `TX_IN_N` |
| `v_compl` | 0.3 V | Current-source headroom to `TX_VDD` |
| `r_out`, `c_out` | 1 MΩ, 0 | Output resistance and capacitance per pin |
| `bias_mode`, `vref_nom`, `v_i5u` | 0, 1.2 V, 0.6 V | Bias (see above) |
| `r_cap` | 1 TΩ | `TX_CAP_P/N` coupling |
| `vth_logic`, `vdd_min` | 0.9 V, 2.97 V | Input threshold, supply-good threshold |

## Alignment with the digital side

| Digital requirement | Source | Model |
|---|---|---|
| `TX_IN_P` = 1 → J (DP high); idle clamp P = 1, N = 0, `TX_EN` = 0 | spec 3.1, `usb_afe_tx_if` | Yes. The clamp state draws no current |
| HS level 400 mV, chirp 800 mV | USB 2.0, `tb_usb_afe_tx_if` | Ideal current source into the terminations |
| `TX_EN` lead = ⌈`t_en` / T_bit⌉ | spec 4.1 | `t_en` is a parameter: sweep it to re-derive the default |
| FS J = DP high, LS J = DM high, `fs_se0` overrides `fs_dat` | spec 3.4, `afe_fsls_bm` | Yes |
| FS / LS edge rates and isolated receiver values | spec 3.4 | Yes |

## Not modelled

The transmission line and reflections, driver output impedance in HS (except `r_out`), pre-emphasis, crossover matching of FS/LS edges, ESD capacitance, the HS driver's real shutdown behaviour (Q4), and supply current except through the outputs.

## Testbench

`veriloga/tb/tb_afe_transceiver.scs` with the checker `tb_afe_transceiver_chk` (`tb_afe_transceiver.va`); run it with `veriloga/tb/run_va_tests.sh transceiver`. The DUT is the device side. The host is an `afe_term` whose 45 Ω terminations and 15 kΩ pull-downs the checker switches.

| Step | Checks |
|---|---|
| FS attach (pull-up, host pull-downs) | DP 3.0 V, DM 0, `RXDP_A` / `RXRCV_A` = 1 |
| HS, both terminations | no current 10 ns after `TX_EN`; J +400 mV ± 5 mV, K −400 mV; 10–90 % edge 0.5 ns; `TX_IN` → line 0.81 ns |
| `TX_IN_P` = `TX_IN_N` | DP = DM = 200 mV |
| chirp (device termination off) | DP 800 mV |
| `TX_EN` = 0 | no current |
| FS J / K / SE0 | levels, receivers, FS rise 4–20 ns, `RXRCV_A` delay 2.0–2.5 ns |
| LS J / K | levels, LS rise 75–300 ns |
| device pull-up + pull-downs | DP 3.0 V |
| `FS_RX_EN_A` = 0, VDD33 = 2.5 V | isolated receiver values |

The P/N check of `afe_hs_tx` prints a message during the P = N step; that message is expected. Not simulated yet.
