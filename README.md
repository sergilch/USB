# USB 2.0 ULPI PHY — Digital Side (Verilog)

The digital, PHY-side ULPI logic of a USB 2.0 transceiver (High-Speed, Full-Speed and Low-Speed), written in synthesizable Verilog-2005. It covers the ULPI pin interface, the ULPI register file, the TX path (holding FIFO, SYNC/PID, bit stuffing, NRZI and serialization with EOP generation), the RX datapath (clock/data recovery interface, NRZI decoding, SYNC detection, unstuffing, deserialization, EOP and error checking, elastic buffer) and the RX-side ULPI blocks (RX data FIFO, RXCMD generation and output arbitration).

The analog front end and the line-state, VBUS and ID detectors are **not** part of this repository.

> **Status:** work in progress. See [Project status](#project-status).

## Features

- **ULPI 1.1 PHY-side interface:** DIR / NXT / STP / DATA[7:0], with bus turnaround, NXT pacing and TXCMD decoding.
- **Register access:** immediate (00h–3Fh) and extended (AFh / EFh, pointer 2Fh) register reads and writes. Register reads follow the fixed ULPI timing (turnaround in the cycle after the last NXT, data in the next one), and pending RXCMDs wait until the read data has been sent.
- **Interface protection:** ULPI holding state. While STP is high outside a transfer, no command is taken and DIR stays low; the RXCMD changes meanwhile go out as one RXCMD when STP falls.
- **Register file:** Vendor/Product ID, Function Control, Interface Control, OTG Control, USB Interrupt Enable Rising/Falling, Status, Latch, Debug and Scratch, with SET/CLR aliases. Extended addresses 00h–3Fh mirror the immediate set (ULPI 1.1 §4). The vendor registers 30h–3Fh hold the AFE trims (a shadow set taken over by an UPDATE strobe), the analog test controls and the power status. VID/PID default to the USB3320 values (0424h / 0007h).
- **Pad wrapper:** `usb_ulpi_phy_pads` puts the ULPI pins (CLK, DATA[7:0], DIR, NXT, STP) and RESETB on X-FAB xh018 `BBSUD8F` digital I/O cells, with the ULPI interface-protection pulls (STP pull-up, DATA pull-downs, switched by Interface Control bit 7), a RESETB synchronizer and a NAND-tree chain.
- **TX path:** 4-byte holding FIFO → SYNC/PID mux → bit stuffer → NRZI encoder → serializer + EOP.
  - HS, FS and LS bit rates selected by XcvrSelect, sampled at packet start.
  - HS EOP is 8 bit times at the inverted level. FS/LS EOP is SE0 for 2 bits, then J.
  - HS underrun detection (`tx_underrun`).
  - OpMode `10` bypass (no bit stuffing, no NRZI) for chirp and test modes.
- **RX datapath:** NRZI decoder → SYNC detect → bit unstuffer → deserializer 1:8 → EOP / RxError check → elastic buffer.
  - HS on the clock recovered by the CDR, with an asynchronous elastic buffer into the local clock domain; tolerates lost SYNC bits (12-bit minimum SYNC) and ±1000 ppm.
  - FS/LS recovered digitally by a DPLL that oversamples D+/D− 40× / 320× on the 480 MHz clock; tolerates the FS ±0.25 % and LS ±1.5 % clock limits and D+/D− skew.
  - Errors: bit-stuff violation, EOP not on a byte boundary, signal lost before the EOP, buffer overflow → `rx_error`.
  - No reception of the PHY's own packets (local-TX hold-off).
- **RX-side ULPI:** RX data FIFO with overrun detection, RxActive/RxError, and RXCMD generation on line-state, VBUS, ID and interrupt changes.
- **Interlocks** keep TX packets and register transfers from interfering with each other on the shared ULPI bus.

## Architecture

```
usb_ulpi_phy_pads           BBSUD8F pads for CLK / DATA / DIR / NXT / STP / RESETB, protection
│                           pulls (Interface Control bit 7), RESETB synchronizer, NAND tree
└── usb_ulpi_phy_top
usb_ulpi_phy_top            phy_if + register file; maps comparators -> VbusState,
│                           XcvrSelect -> TX speed
├── usb_mode_term_ctrl      terminations (pull-up / 45 Ohm / pull-downs), OpMode 10 framing
├── usb_ulpi_reg_file       ULPI register file (immediate set, mirrored at ext 00h-3Fh), IE masks
└── usb_ulpi_phy_if
    ├── usb_ulpi_core
    │   ├── usb_ulpi_input_capture   registers pins, decodes TXCMD / RegWrite / RegRead / ext (AFh/EFh)
    │   ├── usb_tx_datapath          holding -> SYNC/PID mux -> usb_tx_path (bit stuffer -> NRZI -> serializer+EOP)
    │   │   └── usb_tx_holding       4-byte FIFO, paces the Link with NXT, ends packet on STP
    │   ├── usb_ulpi_reg_access      register read/write FSM toward reg_*
    │   ├── usb_ulpi_burst_mux       merges register read data with PHY bursts
    │   └── usb_ulpi_bus_owner       drives DIR / NXT / DATA out + OE, handles turnaround
    └── usb_ulpi_rx_path
        ├── usb_ulpi_rx_handler      RX data FIFO (RX_DEPTH), RxActive/RxError, overrun
        ├── usb_ulpi_rxcmd_gen       RXCMD bytes from linestate/VBUS/ID/interrupt changes
        └── usb_ulpi_out_arbiter     RX data vs RXCMD -> burst into the core
```

`BBSUD8F.v` is the pad cell, copied unchanged from the X-FAB library `IO_CELLS_JIF3V.v`. It needs the UDPs in `VLG_PRIMITIVES.v`. The pad model only models its pull-up / pull-down when compiled with `-DDISPLAY_PD_PU_EN`. These X-FAB files are confidential PDK data and are **not** in this repository: they belong in a local `X-FAB/` directory, which `.gitignore` excludes. To simulate `usb_ulpi_phy_pads`, put `VLG_PRIMITIVES.v` from the xh018 I/O library into `X-FAB/`, together with `BBSUD8F.v`, which holds the `BBSUD8F` cell (from its `` `timescale`` to its `` `endcelldefine``) cut out of `IO_CELLS_JIF3V.v`.

`usb_ulpi_tx_top` is an older, smaller top level: input capture, TX datapath and bus owner only, with no register access.

Each module's header comment holds its detailed spec: pipeline position, timing and corner cases.

### Clocking and conventions

- **Single clock:** everything runs on `clk_bit` (480 MHz). The 60 MHz ULPI domain is the clock enable `ce60`, which is high for one `clk_bit` cycle in eight. Paths in that domain are 8-cycle multicycle paths.
- **Reset:** active-low asynchronous `rst_n`.
- **Speed encoding** follows ULPI XcvrSelect: `00` HS, `01` FS, `10` LS, `11` sent at FS rate.
- **Line encoding:** `txd` J = 1 / K = 0, LSB first. `tx_en` and `tx_se0` go to the transmitter.

### Top-level parameters (`usb_ulpi_phy_top`)

| Parameter  | Default | Meaning                                  |
|------------|---------|------------------------------------------|
| `FS_DIV`   | 40      | `clk_bit` cycles per FS bit (12 Mb/s)    |
| `LS_DIV`   | 320     | `clk_bit` cycles per LS bit (1.5 Mb/s)   |
| `DIV_W`    | 9       | Width of the bit-rate divider counter    |
| `RX_DEPTH` | 8       | Depth of the RX data FIFO                |

## Simulation and synthesis

```sh
./run_tests.sh                 # all testbenches (Icarus Verilog), in parallel
./run_tests.sh ulpi_core rx_   # only testbenches whose name contains one of the words
./run_synth.sh                 # Yosys synthesis smoke test of the top levels
CORNER=slow ./run_synth.sh     # xh018 Liberty corner: typ (default), slow, fast
```

With GNU make installed, `make test`, `make synth`, `make all` and `make clean` do the same (`TB=`, `TOPS=`, `CORNER=`, `JOBS=` as variables).

`run_tests.sh` takes each testbench's build command from its header and puts simulations, logs and VCDs into `build/`. It prints one line per testbench and a summary, and exits non-zero if any testbench fails. Testbenches that need the X-FAB pad model are skipped when `X-FAB/` is missing.

`run_synth.sh` synthesizes `usb_ulpi_phy_top`, `usb_ulpi_phy_pads`, `usb_rx_datapath` and `usb_ulpi_tx_top` with [Yosys](https://yosyshq.net/yosys/). It fails on inferred latches and on `check -assert` problems (undriven or multiply driven nets, loops). With the X-FAB xh018 standard cells in `X-FAB/xh018_lib`, it also maps the design onto D_CELLS_JIHD, requires a complete mapping and reports cells and area; without them it runs generic synthesis only. The pad cells are black boxes. Timing is not analysed yet.

The testbenches are written for [Icarus Verilog](https://steveicarus.github.io/iverilog/). Each testbench's header comment has the exact command and file list it needs. For example:

```sh
iverilog -g2005 -o sim_bs usb_bit_stuffer.v tb_usb_bit_stuffer.v
vvp sim_bs
```

Every testbench checks its own results and ends with `TEST PASSED`, `TEST FAILED: <n> error(s)` or `TEST FAILED: timeout`. Check that line, not the exit code. Each one also writes `tb_<module>.vcd` for viewing in GTKWave or a similar tool.

### Unit testbenches

| Testbench                     | Sources                                              |
|-------------------------------|------------------------------------------------------|
| `tb_usb_bit_stuffer.v`        | `usb_bit_stuffer.v`                                  |
| `tb_usb_tx_serializer.v`      | `usb_tx_serializer.v`                                |
| `tb_usb_tx_sync_mux.v`        | `usb_tx_sync_mux.v`                                  |
| `tb_usb_nrzi_encoder.v`       | `usb_nrzi_encoder.v`                                 |
| `tb_usb_tx_path.v`            | `usb_bit_stuffer.v` `usb_nrzi_encoder.v` `usb_tx_serializer.v` `usb_tx_path.v` |
| `tb_usb_tx_holding.v`         | `usb_ulpi_input_capture.v` `usb_tx_holding.v`        |
| `tb_usb_ulpi_input_capture.v` | `usb_ulpi_input_capture.v`                           |
| `tb_usb_ulpi_bus_owner.v`     | `usb_ulpi_bus_owner.v`                               |
| `tb_usb_ulpi_reg_file.v`      | `usb_ulpi_reg_file.v`                                |
| `tb_usb_rx_nrzi_decoder.v`    | `usb_rx_nrzi_decoder.v`                              |
| `tb_usb_rx_sync_detect.v`     | `usb_rx_sync_detect.v`                               |
| `tb_usb_rx_bit_unstuffer.v`   | `usb_rx_bit_unstuffer.v`                             |
| `tb_usb_rx_deserializer.v`    | `usb_rx_deserializer.v`                              |
| `tb_usb_rx_eop_check.v`       | `usb_rx_eop_check.v`                                 |
| `tb_usb_rx_elastic_buffer.v`  | `usb_rx_elastic_buffer.v`                            |
| `tb_usb_rx_fsls_frontend.v`   | `usb_rx_fsls_frontend.v`                             |
| `tb_usb_rx_hs_frontend.v`     | `usb_rx_hs_frontend.v`                               |
| `tb_usb_rx_status_sync.v`     | `usb_rx_status_flt.v` `usb_rx_status_sync.v`         |
| `tb_usb_line_state.v`         | `usb_line_state.v`                                   |
| `tb_usb_mode_term_ctrl.v`     | `usb_mode_term_ctrl.v`                               |
| `tb_usb_afe_trim_regs.v`      | `usb_afe_trim_regs.v`                                |

### Integration testbenches

`tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core`, `tb_usb_ulpi_phy_if` and `tb_usb_ulpi_phy_pads`, from smallest to largest. They model a ULPI Link at the pins. The model holds each byte until NXT, retries commands that lose to DIR, and flags protocol errors. The testbenches check register contents against a shadow model and rebuild every transmitted packet from `txd` / `tx_en` / `tx_se0` (de-NRZI, de-stuff, EOP timing). 

`tb_usb_rx_datapath` is the top-level RX testbench, a TX→RX loopback. A far-end `usb_tx_path` on its own clock (ppm offset) sends packets through a line model: for HS an ideal CDR with squelch / lock acquisition that drops 2–20 SYNC bits and noise between packets, for FS/LS D+/D− with skew. A raw symbol generator injects protocol errors. Every received packet is compared with the one sent, and `usb_ulpi_rx_handler` behind the DUT must forward exactly the same bytes.

`tb_usb_ulpi_phy_pads` tests register access to the whole digital section through the pads. A Link model clocked by the CLK pin works only on the chip pins. It checks the whole register map against a shadow model, including aliases, RO and unmapped addresses, the extended set and its mirror, and status / latch / debug. It also checks the configuration outputs, RXCMD content, Link retries caused by background RXCMDs, the pad wiring, the NAND tree, the protection pulls and RESETB. Build it with `-DDISPLAY_PD_PU_EN`; without that define it still runs but skips the pull checks.

### AFE behavioural models

The analog front end is not part of this repository, but its behaviour is modelled for the digital testbenches (`AFE_INTEGRATION_PLAN.md`, phase A1). The models are testbench-only Verilog (`afe_*_bm.v`, real-valued, not synthesizable; `run_synth.sh` never reads them):

| Model | Block |
|---|---|
| `afe_line_bm` | DP / DM wires: sums the Norton contributions of all drivers and loads and solves the node voltage |
| `afe_term_bm` | 1.5 kΩ pull-ups, 45 Ω HS terminations, 15 kΩ pull-downs |
| `afe_hs_tx_bm` | HS current driver (`TX_IN_P/N`, `TX_EN`): 17.78 mA, settling time, P/N skew detection, amplitude trim |
| `afe_hs_rx_bm` | HS Schmitt-trigger receiver (`RX_OUT_P/N`) with hysteresis, offset and noise |
| `afe_squelch_bm` | Squelch (125 mV) and HS disconnect (575 mV) detectors with response times |
| `afe_cdr_bm` | Bang-bang (Alexander) CDR: free-running VCO with ppm offset, phase steps, sampling ambiguity, retimed data output |
| `afe_fsls_bm` | FS / LS drivers with slew-rate ramps, single-ended and differential receivers |
| `afe_pll_bm` | PLL lower loop, frequency only: settling time constant, VCO range, frequency-error and dead-clock injection |

Their testbenches: `tb_afe_line` (USB 2.0 levels: HS 400 mV, chirp 800 mV, SE0, FS / LS idle, rise times), `tb_afe_hs_rx` (receiver, squelch, disconnect), `tb_afe_cdr` (CDR lock time and tracking statistics) and `tb_afe_hs_chain` (the full HS receive chain into two `usb_rx_datapath` instances with `HS_ZMIN` 6 / 4, packets with shortened SYNC as behind hubs, checked with the Link's PID and CRC16 checks).

`tb_usb_afe_tx_if` (phase A2) runs the TX path into the analog TX boundary `usb_afe_tx_if` and on through `afe_hs_tx_bm`, `afe_fsls_bm`, terminations and the line model. It checks the AFE pins cycle by cycle against a reference model (`TX_EN` lead / lag, driver select, idle clamp, reset values), the line levels and polarity at HS / FS / LS, and decodes every packet from the line again. A lead sweep shows which `TX_LEAD` puts the whole SYNC on the line for a given driver settling time.

`tb_usb_afe_rx_if` (phase A3) drives HS packets from a far transmitter through the line, the HS receiver and squelch models and either an ideal or the bang-bang CDR model into six `usb_afe_rx_if` + `usb_rx_datapath` pairs with different SYNC thresholds, lock delays and squelch compensation. It checks the boundary pins against a reference model and measures how many wrong bits the CDR may deliver at the start of a 12-bit SYNC, and how slow the squelch detector may be.

For the mixed-signal simulation with the analog blocks (phase A8), `AFE/veriloga/` holds idealized **Verilog-A** models of the PLL, CDR, line transceiver (HS TX, FS/LS, terminations), HS receiver (with squelch and disconnect) and a 3.3 V → 1.8 V LDO. They have the same pins and defaults as the Verilog models above. Documentation: [`AFE/README.md`](AFE/README.md) and `AFE/doc/`. They have not been run in a simulator yet.

`tb_usb_pll_lock_det` (phase A4) runs the lock detector and the CLKOUT generator on the clock of a PLL model: lock time after enable, loss of lock on a frequency error, a missing reference or a dead VCO, the REFSEL settings, and the CLKOUT pulse shape and its glitch-free stop / start.

`tb_usb_afe_fsls` (phase A5) is an FS / LS loopback through the AFE models: a device (the PHY) and a host on a ppm-offset clock, each with `usb_tx_path` → `usb_afe_tx_if` → `afe_fsls_bm` on one line with the pull-up and pull-downs. The device receives through `usb_rx_status_sync` into `usb_line_state` and `usb_rx_datapath`. Packets go both ways at FS and LS with D+ / D− skew; each must arrive intact, the sender must not receive its own packet, and LineState must follow the line voltages without skew glitches and within the latency limits, ending every packet with SE0 → J.

`tb_usb_afe_chirp` (phase A6) puts two PHY ends, a device and a host, on one line with all AFE models (terminations, HS and FS drivers, HS receiver, squelch, CDR, FS receivers) and runs ULPI Link models on top of them: attach, bus reset, the HS handshake (device chirp K, host K-J chirps, both ends switching their terminations), HS packets both ways, disconnect detection, suspend, remote wake-up and resume. The long USB timers are scaled down; the checks cover the line levels (chirp 700 / 400 mV, no J inside a chirp), LineState at both ends, the termination order and every packet.

`tb_usb_pwr_seq` (phase A7) runs the power sequencer with the PLL model, the lock detector, the CLKOUT generator and the AFE boundary blocks behind a model of the isolation cells: power-up, low power with and without CLKOUT, loss of lock, supply loss while transmitting and in low power, and a PLL that does not lock. It checks the order of every step, that CLKOUT only ever stops low, that DIR is held whenever there is no clock, and that no boundary signal is ever undefined while a supply is off.

Copy the integration testbenches' file lists from their headers.

## Project status

- ✅ The TX path and the RX datapath are complete. All 38 testbenches (32 for the RTL, 2 Icarus shadows of the Spectre AMS testbenches, 4 for the AFE behavioural models) pass with Icarus Verilog.
- ✅ TX data boundary to the AFE (`usb_afe_tx_if`: retiming, HS / FS / LS driver select, `TX_EN` lead / lag, idle clamp), verified through the AFE models; not wired into the top level yet.
- ✅ HS receive boundary to the AFE (`usb_afe_rx_if`: RX / CDR enables, isolation, squelch-based CDR lock, squelch-latency compensation), with the lock-time margin measured through the AFE models; not wired into the top level yet.
- ✅ Clocking: `ce60` / CLKOUT generator (`usb_clk_gen`, glitch-free start / stop) and the digital PLL lock detector (`usb_pll_lock_det`, REFSEL decode, loss-of-lock and dead-clock detection), verified with a PLL model; not wired into the top level yet.
- ✅ Receiver status sync and glitch filters (`usb_rx_status_sync`: FS/LS receivers, squelch, disconnect, VBUS / ID debounce) and LineState / HostDisconnect detection (`usb_line_state`: FS / LS skew filter, HS squelch, chirp), verified in an FS / LS loopback through the AFE models; not wired into the top level yet.
- ✅ Mode / termination control (`usb_mode_term_ctrl`: pull-up, HS terminations and pull-downs per the USB3320 table with break-before-make switching; OpMode 10 chirp / resume framing; OpMode 01 driver disable), inside `usb_ulpi_phy_top`; attach, HS handshake, suspend / resume and disconnect verified with two PHY ends through the AFE models.
- ✅ Pad wrapper `usb_ulpi_phy_pads` (BBSUD8F cells), verified for register access at the pins.
- ⏳ The RX datapath is not wired into `usb_ulpi_phy_top` yet; that happens with the full top level.
- ✅ Power sequencer (`usb_pwr_seq`: bias → PLL lock with timeout / retry → isolation off / reset release → CLKOUT → DIR release; low power with and without CLKOUT, relock, supply loss) and the trim / test / power-status registers (`usb_afe_trim_regs`, vendor 30h–3Fh, inside `usb_ulpi_phy_top`); the sequencer is verified with the PLL model and the AFE boundary blocks but not wired into the top level yet.
- ⏳ OTG/VBUS control and the ULPI low-power controller are still to be written. See [WORK_PLAN.md](WORK_PLAN.md).
- ⏳ Not implemented yet. These signals are exported, but no logic reacts to them:
  - OpMode `11` (no SYNC / EOP generation; transmits like `00`)
  - `soft_reset`
  - SuspendM / low-power mode (`dir_hold` is an input reserved for a future low-power controller)
  - LS via FS preamble (XcvrSelect `11`)

## Repository layout

The RTL and testbenches are all in the repository root:

- `usb_*.v`: RTL modules
- `tb_usb_*.v`: self-checking testbenches
- `run_tests.sh`, `run_synth.sh`, `Makefile`: test and synthesis runners (outputs in `build/`, git-ignored)
- `X-FAB/` (local only, not committed): X-FAB xh018 PDK files, i.e. the pad cell `BBSUD8F.v` with its UDPs (needed for `tb_usb_ulpi_phy_pads`) and the D_CELLS_JIHD standard-cell library (Liberty, LEF, Verilog)
- `DOC/`: reference documentation (ULPI 1.1 specification, USB3300 datasheet) and the block diagrams (`DOC/Diagramm/`)
- `WORK_PLAN.md`: development plan for the complete digital section
- `AFE/`: the analog team's block description, idealized Verilog-A models with Spectre testbenches (`AFE/veriloga/`) and the Spectre AMS testbenches that run them with the RTL (`AFE/ams/`, mirrored by the Icarus shadows `tb_ams_*_shadow.v`)
- `AFE_INTEGRATION_PLAN.md`: plan for connecting the analog front end (HS RX, HS TX, CDR + PLL) to the digital core, open interface questions, and the analog and digital blocks still missing

## References

- *UTMI+ Low Pin Interface (ULPI) Specification*, Revision 1.1
- *Universal Serial Bus Specification*, Revision 2.0
- Microchip/SMSC USB3300 Hi-Speed USB Host, Device or OTG PHY with ULPI Low Pin Interface, datasheet

## License

Released under the [MIT License](LICENSE). The third-party documents in `DOC/` are not covered by this license and remain the property of their respective owners.
