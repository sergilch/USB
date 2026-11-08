# USB 2.0 ULPI PHY — Digital Side (Verilog)

The digital, PHY-side ULPI logic of a USB 2.0 transceiver (High-Speed, Full-Speed and Low-Speed), written in synthesizable Verilog-2005. It covers the ULPI pin interface, the ULPI register file, and the TX path (holding FIFO, SYNC/PID, bit stuffing, NRZI and serialization with EOP generation). It also contains the RX-side ULPI blocks (RX data FIFO, RXCMD generation and output arbitration).

The analog front end, the line-state, VBUS and ID detectors, and the RX datapath that recovers data from the line are **not** part of this repository.

> **Status:** work in progress. See [Project status](#project-status).

## Features

- **ULPI 1.1 PHY-side interface:** DIR / NXT / STP / DATA[7:0], with bus turnaround, NXT pacing and TXCMD decoding.
- **Register access:** immediate (00h–3Fh) and extended (AFh / EFh, pointer 2Fh) register reads and writes.
- **Register file:** Vendor/Product ID, Function Control, Interface Control, OTG Control, USB Interrupt Enable Rising/Falling, Status, Latch, Debug and Scratch, with SET/CLR aliases. VID/PID default to the USB3300 values.
- **TX path:** 4-byte holding FIFO → SYNC/PID mux → bit stuffer → NRZI encoder → serializer + EOP.
  - HS, FS and LS bit rates selected by XcvrSelect, sampled at packet start.
  - HS EOP is 8 bit times at the inverted level. FS/LS EOP is SE0 for 2 bits, then J.
  - HS underrun detection (`tx_underrun`).
  - OpMode `10` bypass (no bit stuffing, no NRZI) for chirp and test modes.
- **RX-side ULPI:** RX data FIFO with overrun detection, RxActive/RxError, and RXCMD generation on line-state, VBUS, ID and interrupt changes.
- **Interlocks** keep TX packets and register transfers from interfering with each other on the shared ULPI bus.

## Architecture

```
usb_ulpi_phy_top            phy_if + register file; maps comparators -> VbusState,
│                           XcvrSelect -> TX speed, OpMode 10 -> bypass (no stuff/NRZI)
├── usb_ulpi_reg_file       ULPI register file (immediate + extended), IE rise/fall masks
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

## Simulation

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
| `tb_usb_tx_holding.v`         | `usb_ulpi_input_capture.v` `usb_tx_holding.v`        |
| `tb_usb_ulpi_input_capture.v` | `usb_ulpi_input_capture.v`                           |
| `tb_usb_ulpi_bus_owner.v`     | `usb_ulpi_bus_owner.v`                               |
| `tb_usb_ulpi_reg_file.v`      | `usb_ulpi_reg_file.v`                                |

To run all of them:

```sh
run() { n=$1; shift; iverilog -g2005 -o sim_$n "$@" tb_usb_$n.v && echo "$n: $(vvp sim_$n | grep 'TEST ')"; }
run bit_stuffer        usb_bit_stuffer.v
run tx_serializer      usb_tx_serializer.v
run tx_holding         usb_ulpi_input_capture.v usb_tx_holding.v
run ulpi_input_capture usb_ulpi_input_capture.v
run ulpi_bus_owner     usb_ulpi_bus_owner.v
run ulpi_reg_file      usb_ulpi_reg_file.v
```

### Integration testbenches

`tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core` and `tb_usb_ulpi_phy_if`, from smallest to largest. They model a ULPI Link at the pins. The model holds each byte until NXT, retries commands that lose to DIR, and flags protocol errors. The testbenches check register contents against a shadow model and rebuild every transmitted packet from `txd` / `tx_en` / `tx_se0` (de-NRZI, de-stuff, EOP timing). Copy their file lists from the testbench headers.

## Project status

- ✅ All six unit testbenches pass with Icarus Verilog.
- ⚠️ `usb_tx_sync_mux.v`, `usb_nrzi_encoder.v` and `usb_tx_path.v` are not in the repository yet. `usb_tx_datapath.v` needs them, so the integration testbenches and the top levels do not build until they are added.
- ⏳ Not implemented yet. These signals are exported, but no logic reacts to them:
  - OpMode `01` / `11` (driver disable)
  - `soft_reset`
  - SuspendM / low-power mode (`dir_hold` is an input reserved for a future low-power controller)
  - LS via FS preamble (XcvrSelect `11`)

## Repository layout

All files are in the repository root:

- `usb_*.v`: RTL modules
- `tb_usb_*.v`: self-checking testbenches
- `DOC/`: reference documentation (ULPI 1.1 specification, USB3300 datasheet)

## References

- *UTMI+ Low Pin Interface (ULPI) Specification*, Revision 1.1
- *Universal Serial Bus Specification*, Revision 2.0
- Microchip/SMSC USB3300 Hi-Speed USB Host, Device or OTG PHY with ULPI Low Pin Interface, datasheet

## License

Released under the [MIT License](LICENSE). The third-party documents in `DOC/` are not covered by this license and remain the property of their respective owners.
