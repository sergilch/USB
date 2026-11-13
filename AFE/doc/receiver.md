# Receiver — `afe_receiver` (`AFE/veriloga/afe_receiver.va`)

*Transistor-level design of the same block (180 nm): [receiver_schematic.md](receiver_schematic.md).*

*Idealized model of the HS receive front end: the analog team's differential Schmitt-trigger HS RX block, and the squelch and disconnect detectors, which are not designed yet. Status: written 2026-11-11, not simulated yet (see `AFE/README.md`).*

| Module | Block | Verilog model with the same behaviour |
|---|---|---|
| `afe_hs_rx` | HS receiver (existing analog block) | `afe_hs_rx_bm.v` |
| `afe_squelch` | HS squelch and disconnect envelope detectors (missing, plan 5.1) | `afe_squelch_bm.v` |
| `afe_receiver` | Both, sharing `RX_IN_P/N`, `RX_EN` and the supplies | — |

FS/LS receivers (`RXRCV_A`, `RXDP_A`, `RXDM_A`) are in `afe_fsls_xcvr` ([transceiver.md](transceiver.md)). Whether the Schmitt receiver can also serve as the FS/LS differential receiver is Q5.

## `afe_hs_rx`: differential Schmitt trigger

- `vd = V(RX_IN_P) − V(RX_IN_N) − v_off + noise`.
- `RX_OUT_P` switches to 1 when `vd` > +`v_hys` / 2 and to 0 when `vd` < −`v_hys` / 2, and holds in between: hysteresis by positive feedback, as the analog team describes the block. `RX_OUT_N` is the complement. Delay `t_dly` (0.3 ns), edges `t_rf`.
- **Noise** (`v_noise` > 0): every `t_noise` a new uniform offset in ±`v_noise` is drawn, as in `afe_hs_rx_bm` (default there: 15 mV, here 0). On an idle line (0 V differential) the output then toggles at random. The digital has to tolerate this before squelch and lock: `lock_dly` in `usb_afe_rx_if` and SYNC detection that rearms only on squelch. Turn it on for those checks.
- **Off** (`RX_EN` = 0, `RX_VDD` below `vdd_min`, or `RX_VREF` below `vref_min` when `vref_min` > 0): `RX_OUT_P` = 0, `RX_OUT_N` = 1.
- **Output supply `RX_VDDO`:** outputs swing 0 … V(`RX_VDDO`). Connect it to 1.8 V for the proposed 1.8 V output stage, so that `RX_OUT_P` can feed `CDR_DATA` directly without a 480 Mbit/s level shifter (Q8). Connect it to `RX_VDD` for today's 3.3 V outputs.
- `RX_VREF` is a 1 GΩ input. `c_in` adds input capacitance per pin.

## `afe_squelch`: squelch and disconnect

- **Squelch:** the line counts as active while |`vd`| > `v_sq` (125 mV, between the USB limits: squelch below 100 mV, active above 150 mV). |`vd`| passes zero at every HS transition: with 625 ps edges it stays below 125 mV for about 0.2 ns per bit. So the comparator feeds an envelope that bridges dips shorter than `t_bridge` (1 ns, less than one bit time). `SQUELCH_A` falls once the envelope has been active for `t_sq_on` (4 ns) and rises once the line has been inactive for `t_sq_off` (12 ns) in total. Both filters are inertial: activity shorter than `t_sq_on` − `t_bridge` (3 ns) and gaps shorter than `t_sq_off` are ignored.
- *Why the bridge:* without it, every zero crossing restarted the 4 ns release filter, and the squelch never released on alternating HS data. The first version of this model had that bug; it was found while writing `tb_afe_receiver`. `afe_squelch_bm.v` had it too, hidden by the instantaneous edges of `afe_line_bm`. It now has the same bridge (`T_SQ_BRIDGE` / `T_BRIDGE`), and `tb_afe_hs_rx` tests it with sloped edges. The figures in spec 4.2 did not change.
- **Disconnect:** `DISC_A` = 1 once |`vd`| > `v_disc` (575 mV, USB: 525–625 mV) for `t_disc` (4 ns). It falls at once. A host samples it during the HS EOP: 400 mV normally, 800 mV when the device has gone.
- **Off** (`RX_EN` = 0 or `RX_VDD` low): `SQUELCH_A` = 1, `DISC_A` = 0 (isolated values, spec 3.2 / 3.5).

## Pins of `afe_receiver`

| Pin | Dir | Digital signal | Description |
|---|---|---|---|
| `RX_IN_P`, `RX_IN_N` | in | — | DP, DM |
| `RX_EN` | in | `rx_en_hs` (`usb_afe_rx_if`) | HS receiver and squelch on (new pin, spec 3.2). On in HS mode only |
| `RX_VREF` | in | — | Reference from the bias block (Q9) |
| `RX_OUT_P` | out | — | To `CDR_DATA` of `afe_cdr` |
| `RX_OUT_N` | out | — | Complement (unused by the digital) |
| `SQUELCH_A` | out | `squelch_a` (`usb_afe_rx_if`) | 1 = no HS signal |
| `DISC_A` | out | `host_disc` (`usb_ulpi_phy_top`) | HS disconnect, host mode |
| `RX_VDD`, `RX_GND` | supply | — | 3.3 V |
| `RX_VDDO` | supply | — | Output stages (1.8 V proposed) |

Wrapper parameters: `v_hys`, `v_off`, `v_noise`, `t_dly`, `v_sq`, `t_sq_on`, `t_sq_off`, `t_bridge`, `v_disc`, `t_disc`. For the others, instantiate `afe_hs_rx` / `afe_squelch` directly.

## Parameters

| Module | Parameter | Default | Meaning |
|---|---|---|---|
| `afe_hs_rx` | `v_hys`, `v_off` | 20 mV, 0 | Total hysteresis, input offset |
| | `v_noise`, `t_noise`, `seed0` | 0, 1 ns, 11 | Peak uniform noise, update interval, seed |
| | `t_dly`, `t_rf`, `c_in` | 0.3 ns, 50 ps, 0 | Delay, output edges, input capacitance |
| | `vdd_min`, `vref_min`, `r_vref` | 2.97 V, 0 (off), 1 GΩ | Supply and bias checks |
| `afe_squelch` | `v_sq`, `t_sq_on`, `t_sq_off` | 125 mV, 4 ns, 12 ns | Squelch threshold and filter times |
| | `t_bridge` | 1 ns | Envelope: dips below `v_sq` shorter than this are ignored |
| | `v_disc`, `t_disc` | 575 mV, 4 ns | Disconnect threshold and delay |
| | `t_dly`, `t_rf`, `vdd_min` | 0.1 ns, 50 ps, 2.97 V | Output stage, supply check |
| both | `vth_logic` | 0.9 V | `RX_EN` threshold |

## Alignment with the digital side

| Digital requirement | Source | Model |
|---|---|---|
| `RX_OUT_P` = 1 ↔ DP > DM (J) | spec 3.2, Q3 | Yes |
| Squelch release ≤ 12 ns costs no SYNC bits with `HS_ZMIN` 4 / `LOCK_DLY` 2 | spec 4.2 (A3) | `t_sq_on` = 4 ns. Sweep it up to 16 ns to re-run the A3 squelch sweep |
| Squelch assertion < 8 bit times after EOP; a hold of 6 ns is enough with `SQ_COMP` ≤ 2 | spec 4.2 | `t_sq_off` = 12 ns |
| Disconnect 525–625 mV, sampled during the HS EOP | spec 3.5 | 575 mV, 4 ns |
| HS RX, squelch off outside HS mode (`rx_en_hs`) | `usb_afe_rx_if` | `RX_EN` gates both |

## Not modelled

Frequency response and ISI of the receiver (it switches on the ideal differential voltage), common-mode range and rejection, sensitivity limits beyond `v_hys`, the squelch's dependence on data pattern and edge rate, and the threshold trims (`RX_HYST`, `RX_VTH`, `SQ_VTH`, `DISC_VTH`, spec 6). The parameters stand in for the trims.

## Testbench

`veriloga/tb/tb_afe_receiver.scs` with the checker `tb_afe_receiver_chk` (`tb_afe_receiver.va`); run it with `veriloga/tb/run_va_tests.sh receiver`. The line is an ideal differential source at 200 mV common mode: a slow or static ramp, plus an alternating J/K pattern at 480 Mbit/s with 625 ps edges.

| Step | Checks |
|---|---|
| ramp −50 → +50 → −50 mV in 1 µs | `RX_OUT_P` switches at +10 / −10 mV (± 0.5 mV); squelched |
| 400 mV pattern | `SQUELCH_A` falls 4.1–4.7 ns after the start; `RX_OUT_P` 0.30–0.36 ns after DP − DM = 0; `DISC_A` = 0 |
| pattern stops | `SQUELCH_A` rises 12 ns later |
| 90 mV / 160 mV pattern | not released / released |
| 2 ns burst | ignored |
| static 500 / 650 mV | `DISC_A` 0 / 1, delay 4.1–4.3 ns |
| `RX_EN` = 0, `RX_VDD` = 2.5 V | isolated outputs |

Not simulated yet.
