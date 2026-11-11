# LDO — `afe_ldo` (`AFE/veriloga/afe_ldo.va`)

*Idealized model of a 3.3 V → 1.8 V low-dropout regulator with UVLO, soft start, power-good and power-on reset. The block does not exist yet. Whether the 1.8 V supplies come from an internal LDO, as in the USB3320, or from outside is still open (Q13). The model fixes what the digital side expects from it. Status: written 2026-11-11, not simulated yet (see `AFE/README.md`).*

## Use in the PHY

Two instances, one per 1.8 V domain (spec 1):

| Instance | VOUT | Load | `LDO_EN` |
|---|---|---|---|
| digital | VDD18 | digital core on D_CELLS_JIHD, BBSUD8F ULPI pads | **tied high** (to VIN or a pin): the digital core can't switch on its own supply |
| analog | VDD18A | `afe_pll`, `afe_cdr` | from the power sequencer (`ldo_en`, spec 3.6), once the digital runs, or tied high |

`PWR_GOOD` and `POR_N` of the digital instance are the `pwr_good` and `por_n` inputs of spec 3.6. `POR_N` is the power-on reset that `usb_clk_gen` and `usb_pll_lock_det` use instead of RESETB.

## Function

- **Enable:** `LDO_EN` above `vth_en` (0.9 V, an absolute threshold, so it works from 1.8 V or 3.3 V logic) **and** VIN above the UVLO (on at `uvlo_r` = 2.7 V rising, off at `uvlo_f` = 2.5 V falling).
- **Regulation:** VOUT is a Thevenin source `v_set` behind `r_out` (0.05 Ω load regulation) with smooth current limits: `i_lim` (50 mA) sourcing, `i_sink` (1 mA) sinking. The load current is drawn from VIN.

  `v_set = vout_nom · ramp + (V(VIN) − vin_nom) · 10^(−psrr_db / 20)`, limited to `V(VIN) − v_drop`.

  The target reaches the output through a single pole at `f_bw` (1 MHz), which shapes line steps and the soft start. The load-step response is set by `r_out` and the output capacitor in the testbench. The model has no loop that could ring.
- **Soft start:** after enable, the ramp goes linearly from 0 to `vout_nom` in `t_ss` (50 µs). When disabled it ramps down in `t_off` (1 µs), and `r_dis` (1 kΩ) actively discharges VOUT.
- **Dropout:** VOUT follows VIN − `v_drop` (0.2 V) once VIN < `vout_nom` + `v_drop` = 2.0 V. Above the 2.5–2.7 V UVLO this does not happen with the defaults; lower the UVLO to see it.
- **Quiescent current:** `i_q` (50 µA) from VIN while enabled.
- **Power good:** `PWR_GOOD` = 1 once VOUT has been above `pg_r` (1.62 V = 1.8 V − 10 %, the lowest corner of the digital library) for `t_pg` (10 µs). It falls at once when VOUT drops below `pg_f` (1.55 V).
- **Power-on reset:** `POR_N` rises `t_por` (100 µs) after `PWR_GOOD` and falls together with it.
- **Output levels:** `PWR_GOOD` and `POR_N` swing 0 … V(VOUT). They are valid in the domain they supervise and low while it is down, so they can feed the 1.8 V logic directly.

## Pins

| Pin | Dir | Digital signal | Description |
|---|---|---|---|
| `VIN` | supply | — | VDD33 (3.3 V) |
| `VOUT` | supply out | — | VDD18 or VDD18A. Output capacitor and load go in the testbench |
| `GND` | supply | — | Ground |
| `LDO_EN` | in | `ldo_en` (VDD18A instance only) | Enable |
| `PWR_GOOD` | out | `pwr_good` | Supply valid |
| `POR_N` | out | `por_n` | Power-on reset, active low |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `vout_nom`, `vin_nom` | 1.8 V, 3.3 V | Nominal output and input |
| `v_drop` | 0.2 V | Dropout voltage |
| `r_out` | 0.05 Ω | Output resistance (load regulation) |
| `i_lim`, `i_sink` | 50 mA, 1 mA | Current limits (source / sink) |
| `i_q` | 50 µA | Quiescent current |
| `psrr_db` | 40 dB | DC supply rejection |
| `f_bw` | 1 MHz | Regulation bandwidth (target pole) |
| `t_ss`, `t_off`, `r_dis` | 50 µs, 1 µs, 1 kΩ | Soft start, ramp-down, discharge |
| `vth_en` | 0.9 V | `LDO_EN` threshold |
| `uvlo_r`, `uvlo_f` | 2.7 V, 2.5 V | Undervoltage lockout |
| `pg_r`, `pg_f`, `t_pg` | 1.62 V, 1.55 V, 10 µs | Power-good thresholds and delay |
| `t_por` | 100 µs | POR extension after power good |
| `t_rf` | 10 ns | Edges of the status outputs and switches |

## Alignment with the digital side

| Digital requirement | Source | Model |
|---|---|---|
| Supplies valid before the digital leaves reset; `pwr_good`, then the sequence of spec 5 | spec 3.6, 5 | `PWR_GOOD`, then `POR_N` after `t_por` |
| Digital library characterised down to 1.62 V (slow corner) | spec 7.2 | `pg_r` = 1.62 V |
| No back-powering of an unpowered domain | spec 1 | The pass device conducts only from VIN to VOUT (`i_sink` aside); isolation of the signals is the job of the other blocks' `vdd_min` checks |
| Power-down: the PLL's supply can be switched off in suspend | spec 5 | `LDO_EN` of the VDD18A instance; with `r_dis` the domain discharges in microseconds |

## Not modelled

The real loop dynamics and their stability with the output capacitor and its ESR, load-transient undershoot, frequency-dependent PSRR, noise, a bandgap (the reference is ideal), thermal shutdown, and the reverse current when VIN falls below VOUT (only the small `i_sink` flows).

## Testbench

`veriloga/tb/tb_afe_ldo.scs` with the checker `tb_afe_ldo_chk` (`tb_afe_ldo.va`); run it with `veriloga/tb/run_va_tests.sh ldo`. VIN ramps 0 → 3.3 V in 100 µs with `LDO_EN` tied to VIN. The output has 1 µF and a load the checker switches.

| Step | Checks |
|---|---|
| power-up, 10 mA | VOUT ≈ 0 at the 2.7 V UVLO; 1.62 V after 45 µs ± 1.5 µs; `PWR_GOOD` 10 µs later; `POR_N` 100 µs after `PWR_GOOD`; VOUT 1.8 V ± 5 mV |
| 40 mA | VOUT 1.8 V ± 5 mV |
| 10 Ω overload | VOUT 0.40–0.55 V (current limit), `PWR_GOOD` and `POR_N` low |
| back to 10 mA | recovered, `PWR_GOOD` and `POR_N` high |
| VIN 3.3 → 3.0 V | VOUT −3 mV ± 0.5 mV (PSRR 40 dB) |
| VIN 2.4 V, then 3.3 V | off (`PWR_GOOD`, `POR_N` low), then restart |
| `LDO_EN` = 0 | VOUT discharged below 50 mV |

Not simulated yet.
