# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

The digital ULPI side of a USB 2.0 PHY (HS / FS / LS), written in Verilog-2005. Every RTL file is `usb_*.v`, every testbench is `tb_<module>.v`, and all of them sit flat in the repo root. There is no build system, Makefile or git history.

## Simulation (Icarus Verilog)

Each testbench's header comment has the exact `iverilog` command and file list it needs. Read that header and use it rather than guessing at dependencies. Pattern:

```sh
iverilog -g2005 -o sim_bs usb_bit_stuffer.v tb_usb_bit_stuffer.v
vvp sim_bs
```

- Each testbench self-checks. It prints `TEST PASSED`, or `TEST FAILED: <n> error(s)`, or `TEST FAILED: timeout` from a watchdog. Check this line, not the exit code.
- Each testbench writes `tb_<module>.vcd` for waveform viewing.
- Unit testbenches: `tb_usb_bit_stuffer`, `tb_usb_tx_serializer`, `tb_usb_tx_holding` (also needs `usb_ulpi_input_capture.v`), `tb_usb_ulpi_input_capture`, `tb_usb_ulpi_bus_owner`, `tb_usb_ulpi_reg_file`.
- Integration testbenches: `tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core` and `tb_usb_ulpi_phy_if`, from smallest to largest. Their file lists are long. Copy them from the header.

**Missing sources:** the integration file lists include `usb_tx_sync_mux.v`, `usb_nrzi_encoder.v` and `usb_tx_path.v`, but none of these files are in the repo yet. `usb_tx_datapath.v` instantiates `usb_tx_sync_mux` and `usb_tx_path`. So only the unit testbenches build until those files are added. Also, `iverilog` was not installed on this machine when this file was written.

## Architecture

Hierarchy, top down:

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
    │   ├── usb_ulpi_burst_mux       merges register read data with PHY bursts (arb_*)
    │   └── usb_ulpi_bus_owner       drives DIR / NXT / DATA out + OE, handles turnaround
    └── usb_ulpi_rx_path
        ├── usb_ulpi_rx_handler      RX data FIFO (RX_DEPTH), RxActive/RxError, overrun
        ├── usb_ulpi_rxcmd_gen       RXCMD bytes from linestate/VBUS/ID/interrupt changes
        └── usb_ulpi_out_arbiter     RX data vs RXCMD -> ext_* burst into the core
```

`usb_ulpi_tx_top` is an older, smaller top level: capture + TX datapath + bus owner, with no register access. Its register and RX hooks are left as open ports. `tb_usb_ulpi_tx_top` still tests it.

### Rules that hold across all files

- **One clock.** Everything runs on `clk_bit` (480 MHz). The 60 MHz ULPI domain is the clock enable `ce60`: high for one `clk_bit` cycle in eight, aligned with clk60. Logic in the ULPI domain must update only on `ce60` (some submodules call the port `ce`). Signals in that domain are 8-cycle multicycle paths. Active-low async reset is `rst_n`.
- **Speed encoding** is ULPI XcvrSelect everywhere: `00` HS, `01` FS, `10` LS, `11` sent at FS rate (LS-via-FS-preamble is not implemented). Speed is sampled at packet start. FS/LS bit rates come from the `FS_DIV=40` / `LS_DIV=320` dividers on `clk_bit`, and `DIV_W` sets the counter width.
- **Line encoding:** `txd` J = 1 / K = 0, LSB first. HS EOP is 8 bit times at the inverted level. FS/LS EOP is SE0 for 2 bits (`tx_se0`), then J for 1. In HS the serializer needs a word every `ce60`. If one is missing, the packet ends with an EOP and `tx_underrun` pulses.
- **Keeping TX and register transfers apart** (see `usb_ulpi_core.v` header): a register command is not acknowledged while `usb_tx_holding` is busy. TXCMD decode is inhibited while `reg_link_busy` is set, because payload, address and data bytes can look like commands. The bus owner never takes the bus while either transfer is active. Keep these interlocks when changing capture, holding, reg_access or bus_owner.
- **Bit stuffing:** the counter restarts at each packet, and SYNC goes through as ordinary data. A stuff bit is still inserted when six 1s end the packet.
- **Not implemented yet** (exported only, no logic reacts to them): OpMode `01`/`11` driver disable, `soft_reset`, SuspendM / low-power (`dir_hold` is an input from the future low-power controller). The RX datapath (`rx_*`), the line-state, VBUS and ID detectors, and the AFE are also outside this repo.

### Testbench style

The integration testbenches model a ULPI Link at the pins. The model holds each byte until NXT, retries a command when it loses to DIR, and flags protocol errors. They check register contents against a shadow model and rebuild every TX packet from `txd`/`tx_en`/`tx_se0` (de-NRZI, de-stuff, EOP timing). Register data deliberately uses bytes that look like commands (40h, 4Fh, 80h, AFh, C0h, EFh, 2Fh). New testbenches should follow the same pattern: an `errors` counter, the `TEST PASSED`/`TEST FAILED` line, a timeout watchdog and a VCD dump.

Each module's header comment holds its detailed spec (pipeline position, timing, corner cases). Read it before you edit the module, and keep it up to date.
