# CDR — `afe_cdr` (`AFE/veriloga/afe_cdr.va`)

*Idealized model of the upper loop of the analog team's PLL-assisted CDR block. It recovers `clk_rx` and the retimed data `hs_rxd` from the HS receiver output. Status: written 2026-11-11, not simulated yet (see `AFE/README.md`).*

## Function

```
CDR_DATA (RX_OUT_P) ─► Alexander PD ─UP/DN─► charge pump ─► filter C1 ‖ (R8 + C2) ─CDR_CH_OUT─┐
                         ▲  │ data sample                                                      ▼
                         │  └─► HS_RXD (retimed data, t_cq after the rising edge)        ring VCO ◄── CDR_V_IN_2
                         └──────────────────────── CLK_RX ◄───────────────────────────────┘        (from the PLL)
```

- **VCO:** `f = f_coarse(V(CDR_V_IN_2)) · (1 + ppm_mis · 10⁻⁶) + kvco_f · (V(CDR_CH_OUT) − vf_mid)`. `f_coarse` is the PLL's tuning curve (the same `f_min`, `f_max`, `kvco`, `v_fmin`), because the CDR VCO is a matched replica of the PLL VCO. With `CDR_V_IN_2` tied to `CDR_CH_OUT_PLL` the CDR free-runs at 480 MHz · (1 + `ppm_mis`) while there is no data. That is assumption D1 of `WORK_PLAN.md`: `clk_rx` keeps running and the elastic buffer's write side stays alive. `ppm_mis` is the VCO mismatch of risk R3.
- **Alexander phase detector:** `CDR_DATA` is sampled on the rising `CLK_RX` edge (data) and on the falling edge (edge sample). For a data transition between two rising edges:

| Edge sample equals | Meaning | Charge pump |
|---|---|---|
| previous data bit | transition after the falling edge: the clock is early | down (slower) for one bit |
| new data bit | transition before it: the clock is late | up (faster) for one bit |
| — (no transition) | no information | off |

- **Loop filter:** the analog block's topology, `C1` shunt and `R8` + `C2` in series, on pin `CDR_CH_OUT`. Proportional path: one decision moves the VCO by `icp · r8 · kvco_f` = 30 MHz for one bit, which shifts the next edges by T_bit / 16 = 130 ps. That is the `STEP` default of `afe_cdr_bm`, for which `tb_afe_cdr` measured the lock statistics in spec 4.2. Integral path: one net decision changes the frequency by `icp · T_bit / c2 · kvco_f` = 125 kHz (260 ppm), so ±1000 ppm is tracked after about 4 net decisions.
- **Retimed data `HS_RXD`** (new pin, Q1): the data sample of the rising edge, `t_cq` after that edge. The digital (`usb_afe_rx_if`) captures it with the next rising `CLK_RX` edge, which gives setup T_bit − `t_cq` = 1.78 ns and hold `t_cq` = 0.3 ns. The spec asks for ≥ 0.4 ns / ≥ 0.1 ns (spec 4.2). Polarity: 1 = J (`CDR_DATA` high = DP > DM, Q3).
- **Ambiguous samples** (`t_amb` > 0): a sample taken less than `t_amb` after a `CDR_DATA` crossing is random, which models metastability. The `afe_cdr_bm` default is 0.03 ns. The default here is 0 (ideal).
- **`CDR_EN` = 0, or `VDD18A` below `vdd_min`:** `CLK_RX` stops low, `HS_RXD` = 1 (the isolated value, spec 3.2), the charge pump is off, and `CDR_CH_OUT` is pulled to `vf_mid` through `r_rst`. The VCO phase is frozen, so after enable the CDR starts at an arbitrary phase relative to the data.

## Pins

| Pin | Dir | Digital signal | Description |
|---|---|---|---|
| `CDR_DATA` | in | — | Data from `RX_OUT_P` of the HS receiver (1.8 V logic) |
| `CDR_EN` | in | `cdr_en` (`usb_afe_rx_if`) | 1 = CDR on. The digital turns it on in HS mode only (proposed pin) |
| `CDR_V_IN_2` | in | — | Coarse tuning voltage from `CDR_CH_OUT_PLL` of `afe_pll`. High impedance |
| `CLK_RX` | out | `clk_rx` | Recovered clock. Only `usb_rx_hs_frontend`, the HS decoder and the write side of the HS elastic buffer run on it |
| `HS_RXD` | out | `hs_rxd_a` (`usb_afe_rx_if`) | Retimed data |
| `CDR_CH_OUT` | inout | — | Fine control voltage (observation, analog test bus) |
| `VDD18A`, `VSS18A` | supply | — | 1.8 V analog supply |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `f_min`, `f_max`, `kvco`, `v_fmin` | 400 MHz, 500 MHz, 200 MHz/V, 0.5 V | Coarse curve, **equal to `afe_pll`** |
| `ppm_mis` | 0 | Coarse mismatch against the PLL VCO, in ppm. Use ±1000 for the frequency-tracking check (host ±500 + own ±500) |
| `kvco_f`, `vf_mid` | 300 MHz/V, 0.9 V | Fine tuning |
| `icp` | 100 µA | Charge pump |
| `r8`, `c2`, `c1` | 1 kΩ, 500 pF, 0.1 pF | Loop filter (idealized values; `c2` is far too large for silicon and stands for the integral gain only) |
| `v_cp_marg`, `r_rst` | 0.1 V, 100 Ω | Compliance; filter reset while off |
| `t_cq` | 0.3 ns | `CLK_RX` rise → `HS_RXD` (`afe_cdr_bm` `T_CQ`) |
| `t_amb` | 0 | Ambiguity window of the samplers |
| `jit_rms`, `seed0` | 0, 5 | VCO period jitter (Gaussian), seed |
| `vth_logic`, `vdd_min`, `t_rf`, `pts` | 0.9 V, 1.5 V, 50 ps, 10 | As in `afe_pll` |

## Alignment with the digital side

| Digital requirement | Source | Model |
|---|---|---|
| `clk_rx` free-runs near 480 MHz without data | D1, spec 2 | Coarse input from the PLL, no fine correction without transitions |
| Tracks ±1000 ppm over 1027-byte packets (16-event elastic buffer) | spec 4.2, `tb_usb_rx_datapath` | Integral path, `ppm_mis` |
| Correct bits by the 7th bit after the first transition (`HS_ZMIN` 4, `LOCK_DLY` 2: up to 6 wrong bits) | spec 4.2 (A3 requirement for Q2) | To be measured with this model (same proportional step as `afe_cdr_bm`, which locked within 0–3 bits without jitter, worst case 9–16 bits at 0.15 UI) |
| `hs_rxd` setup / hold ≥ 0.4 / 0.1 ns at the capture flop | spec 4.2 | 1.78 / 0.3 ns before routing |
| No lock output: `hs_cdr_lock` is generated digitally, `lock_dly` bits after the squelch release | `usb_afe_rx_if` | No lock pin |
| Isolated values: `HS_RXD` = 1, `CLK_RX` static | spec 3.2 | Yes |

## Not modelled

The PD's metastability beyond `t_amb`, charge-pump mismatch, VCO phase noise beyond white period jitter, the coarse loop's own ripple on `CDR_V_IN_2`, and a 1:4 demultiplexed output (spec 7.2, Q1 / Q12: if the analog team agrees, `HS_RXD` becomes 4 pins with a ÷4 clock).

## Testbench

`veriloga/tb/tb_afe_cdr.scs` with the checker `tb_afe_cdr_chk` (`tb_afe_cdr.va`); run it with `veriloga/tb/run_va_tests.sh cdr`. `CDR_V_IN_2` is held at 0.9 V, which is 480 MHz on the coarse curve; the PLL itself is covered by `tb_afe_pll`.

- **Generator:** idle at 0 (SE0) → SYNC (12 bits, every 4th packet 32) → PRBS7 payload → 8-bit EOP → idle of 20–60 bits plus a random fraction of a bit. The fraction gives every packet a new start phase.
- **Packets:** 40 short packets (64 bits) at 0 ppm, then 2 + 2 packets of 1027 bytes at +1000 / −1000 ppm.
- **Margin** at every rising `CLK_RX` edge: the distance of the sampling instant from the nearest bit boundary of `CDR_DATA`. The lock time of a packet is the number of bits from the first transition up to the last edge with a margin below 0.15 UI. It must be ≤ 6 bits in every packet (spec 4.2), and the mean and worst case are printed. The long packets must not lose lock.
- `HS_RXD` must equal the previous sample, and there must be no bit slip between consecutive edges, wherever both margins are good.
- `HS_RXD` timing at the capture flop: setup ≥ 0.4 ns, hold ≥ 0.1 ns.
- After the last packet: free-running clock 480 MHz ± 0.25 %. Then `CDR_EN` = 0: `CLK_RX` low and quiet, `HS_RXD` = 1.

For the jitter statistics of spec 4.2, override the DUT (`jit_rms`, `t_amb`) and raise `n_short`. Not simulated yet.
