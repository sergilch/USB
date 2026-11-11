# PLL — `afe_pll` (`AFE/veriloga/afe_pll.va`)

*Idealized model of the lower loop of the analog team's PLL-assisted CDR block. It generates the 480 MHz `clk_bit` of the whole digital core. Status: written 2026-11-11, not simulated yet (see `AFE/README.md`).*

## Function

```
CDR_FREF ─► PFD ─UP/DN─► charge pump ─► loop filter ─CDR_CH_OUT_PLL─► ring VCO ─┬─► CLK_BIT_A (480 MHz)
              ▲          (icp)          C4 ‖ (R2 + C3)        │                  │
              └────────────── ÷N (20, or 25 / 20 from REFSEL) ◄┼──────────────────┘
                                                               └─► CDR_V_IN_2 of afe_cdr (coarse tuning)
CDR_FREF ─► buffer ─► REF_DIG (to the digital lock detector)
```

- **PFD:** tri-state phase-frequency detector on the rising edges of `CDR_FREF` and of the divider output. The reset is ideal: no reset pulse and no dead zone.
- **Charge pump:** ±`icp`. Compliance is smooth (tanh): the current fades out within `v_cp_marg` of either rail, so the control voltage stays between the rails even when the reference is missing.
- **Loop filter:** the analog block's topology, `C4` shunt and `R2` + `C3` in series. The filter node is the pin `CDR_CH_OUT_PLL`.
- **VCO:** `f = f_min + kvco · (V(CDR_CH_OUT_PLL) − v_fmin)`, limited to [`f_min`, `f_max`]. With the defaults that is 400 MHz up to 0.5 V, 480 MHz at 0.9 V, and 500 MHz from 1.0 V.
- **Feedback divider:** with `prog_div` = 0 it is a fixed ÷`div_01` (20), as in the analog block today. With `prog_div` = 1 it is selected by `REFSEL1/0`, with the same code as `usb_pll_lock_det`:

| REFSEL1 REFSEL0 | Reference | N (parameter, default) | Digital decode (`usb_pll_lock_det`) |
|---|---|---|---|
| 0 0 | 19.2 MHz | `div_00` = 25 | `fb_div` = 25 |
| 0 1 | 24 MHz | `div_01` = 20 | `fb_div` = 20 (default) |
| 1 0 | 26 MHz | `div_10` = 20 | `refsel_err` = 1: 480 / 26 is not an integer and needs a fractional divider (Q6). With ÷20 the VCO runs into `f_max`, so the digital never sees lock, as in `tb_usb_pll_lock_det`. |
| 1 1 | reserved | `div_11` = 20 | `refsel_err` = 1, treated as 24 MHz |

- **`PLL_EN` = 0, or `VDD18A` below `vdd_min`:** `CLK_BIT_A` stops low, the PFD and charge pump are reset, and the loop filter is discharged through `r_dis`. The VCO restarts at `f_min`, as in `afe_pll_bm` (`F_START` = 400 MHz). The digital must stop CLKOUT before it drops `PLL_EN` (`usb_clk_gen` `clk_on` = 0, spec 4.3). The model itself just stops the clock.
- **`REF_DIG`:** a buffered copy of `CDR_FREF` (delay `t_ref_dly`). It runs whenever `VDD18A` is up, independent of `PLL_EN`, because the lock detector's heartbeat check needs the reference while the PLL is off or dead (proposed pin, Q7).

## Pins

| Pin | Dir | Digital signal | Description |
|---|---|---|---|
| `CDR_FREF` | in | — (crystal oscillator / REFCLK buffer) | Reference clock, 1.8 V CMOS |
| `PLL_EN` | in | `pll_en` | 1 = PLL on (proposed pin, spec 3.3) |
| `REFSEL1`, `REFSEL0` | in | `refsel[1:0]` | Divider select, static. Ignored when `prog_div` = 0 |
| `CLK_BIT_A` | out | `clk_bit` | 480 MHz clock into the digital clock tree |
| `REF_DIG` | out | `ref_clk` of `usb_pll_lock_det` | Buffered reference |
| `CDR_CH_OUT_PLL` | inout | — | Control voltage. Connect it to `CDR_V_IN_2` of `afe_cdr` |
| `VDD18A`, `VSS18A` | supply | — | 1.8 V analog supply (from `afe_ldo`) |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `f_min`, `f_max` | 400 MHz, 500 MHz | VCO range (`afe_pll_bm`: `F_MIN`, `F_MAX`). **Keep equal in `afe_cdr`** |
| `kvco`, `v_fmin` | 200 MHz/V, 0.5 V | Tuning curve. **Keep equal in `afe_cdr`** |
| `icp` | 20 µA | Charge-pump current |
| `r2`, `c3`, `c4` | 34.5 kΩ, 15.3 pF, 1.53 pF | Loop filter |
| `v_cp_marg` | 0.1 V | Charge-pump compliance to the rails |
| `r_dis` | 1 kΩ | Filter discharge while off |
| `prog_div`, `div_00` … `div_11` | 1, 25 / 20 / 20 / 20 | Divider (see the table above) |
| `vth_logic`, `vdd_min` | 0.9 V, 1.5 V | Logic threshold, supply-good threshold |
| `t_rf`, `t_ref_dly` | 50 ps, 0.2 ns | Output edges, reference buffer delay |
| `pts` | 10 | Time steps per VCO period (`$bound_step`) |
| `f_err` | 0 | Fault injection: `CLK_BIT_A` = N · f_ref · (1 + `f_err`), as with a broken feedback path. 3e-3 reproduces the +0.3 % loss-of-lock case of `tb_usb_pll_lock_det`. |
| `jit_rms`, `seed0` | 0, 7 | Gaussian period jitter of `CLK_BIT_A`. It is not seen by the loop, so the output phase wanders slowly against the reference; the digital only needs the per-period figure. |

## Loop design (defaults)

Loop constant `K = icp · kvco / N` = 20 µA · 200 MHz/V / 20 = 200 A·Hz/V. The crossover follows from f_c² = K · √(b+1) / (4π² · (C3 + C4)). With `b` = `C3` / `C4` = 10, the zero sits at f_c / √(b+1) and the pole at f_c · √(b+1):

| Quantity | Value |
|---|---|
| Crossover f_c | 1.0 MHz (f_ref / 24) |
| Zero 1 / (2π R2 C3) | 0.30 MHz |
| Pole (C3 + C4) / (2π R2 C3 C4) | 3.3 MHz |
| Phase margin | 56° |
| Slew of the control voltage while the PFD sees a frequency error | about `icp` / (C3 + C4) = 1.2 V/µs |
| Expected lock (start at `f_min`, 0 V) | a few µs, well inside the 45 µs to ±0.08 % that the 100 µs lock budget requires (spec 4.3) |

These values exist so that the model closes its loop. The transistor-level values (`CDR_R2`, `CDR_C3`, `CDR_C4`, the real charge-pump current and the VCO gain) replace them once the analog team delivers them.

## Alignment with the digital side

| Digital requirement | Source | Model |
|---|---|---|
| `clk_bit` = 480 MHz from 24 MHz (÷20) or 19.2 MHz (÷25) | spec 2, 3.3; `usb_pll_lock_det` | ÷N from REFSEL, the same code as the lock detector |
| Lock detector counts `clk_bit` over 256 `ref_clk` cycles: 5120 ± 5 at 24 MHz | `usb_pll_lock_det` | `REF_DIG` is the reference itself, so the count is exact once the loop has settled |
| PLL inside ±0.08 % within 45 µs of `PLL_EN` | spec 4.3 (A4 result) | Loop bandwidth 1 MHz |
| 26 MHz with ÷20 must not lock | `tb_usb_pll_lock_det` | VCO limit `f_max` = 500 MHz < 520 MHz |
| Clock stops low when the PLL is off; restart from `f_min` | `afe_pll_bm` | Yes |
| Reference keeps running for the dead-clock check | `usb_pll_lock_det` heartbeat | `REF_DIG` does not depend on `PLL_EN` |

## Not modelled

Phase noise beyond white period jitter, reference spurs, charge-pump mismatch and leakage, the PFD reset pulse, VCO gain variation over the range, supply sensitivity, the divider's own delay, and a lock-detect output (lock is judged digitally).

## Testbench

`veriloga/tb/tb_afe_pll.scs` with the checker `tb_afe_pll_chk` (`tb_afe_pll.va`); run it with `veriloga/tb/run_va_tests.sh pll`. It measures the `CLK_BIT_A` frequency over blocks of 1024 periods, and the window count of `usb_pll_lock_det` (`CLK_BIT_A` edges per 256 `REF_DIG` periods).

| Phase | Checks |
|---|---|
| 24 MHz, REFSEL 01, `PLL_EN` = 1 for 80 µs | settled to ±0.08 % within 45 µs; windows 5120 ± 1 after settling; 480 MHz ± 200 ppm; control voltage 0.85–0.95 V |
| `PLL_EN` = 0 | `CLK_BIT_A` low and without edges; 48 ± 1 `REF_DIG` edges in 2 µs; control voltage < 50 mV |
| 19.2 MHz, REFSEL 00 | settled within 30 µs; windows 6400 ± 1; 480 MHz |
| 26 MHz, REFSEL 10 | no window inside 4726 ± 5; `CLK_BIT_A` at 500 MHz (VCO limit) |

Checker parameters: `ppm_ref` (reference offset), `t_set_24`, `t_set_19`, `t_run`. Not simulated yet.
