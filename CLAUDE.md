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
- Unit testbenches: `tb_usb_bit_stuffer`, `tb_usb_tx_serializer`, `tb_usb_tx_sync_mux`, `tb_usb_nrzi_encoder`, `tb_usb_tx_path` (needs stuffer, NRZI and serializer), `tb_usb_tx_holding` (also needs `usb_ulpi_input_capture.v`), `tb_usb_ulpi_input_capture`, `tb_usb_ulpi_bus_owner`, `tb_usb_ulpi_reg_file`.
- RX unit testbenches: `tb_usb_rx_nrzi_decoder`, `tb_usb_rx_sync_detect`, `tb_usb_rx_bit_unstuffer`, `tb_usb_rx_deserializer`, `tb_usb_rx_eop_check`, `tb_usb_rx_elastic_buffer`, `tb_usb_rx_fsls_frontend`, `tb_usb_rx_hs_frontend` (each needs only its own module).
- Integration testbenches: `tb_usb_ulpi_tx_top`, `tb_usb_ulpi_core`, `tb_usb_ulpi_phy_if` and `tb_usb_ulpi_phy_pads` (register access through the pads; build it with `-DDISPLAY_PD_PU_EN` so the pad pulls are modelled), from smallest to largest, and `tb_usb_rx_datapath` (TX→RX loopback: a far-end `usb_tx_path` on a ppm-offset clock, an HS CDR/squelch and FS/LS D+/D− line model, a raw symbol generator for protocol errors, and `usb_ulpi_rx_handler` behind the DUT). Their file lists are long. Copy them from the header.

**Status:** all 22 testbenches build and pass with Icarus Verilog (installed on this machine). The pad wrapper `usb_ulpi_phy_pads` was added on 2026-11-10. The TX path was completed and the RX datapath (`usb_rx_*.v`) added on 2026-11-08. The RX datapath is not wired into `usb_ulpi_phy_top` yet (work plan, Phase 8): `usb_ulpi_phy_top` still takes `rx_*` as ports, and `usb_rx_datapath` drives exactly that interface.

## Architecture

Hierarchy, top down:

```
usb_ulpi_phy_pads           BBSUD8F pads (CLK, DATA[7:0], DIR, NXT, STP, RESETB), ULPI protection
│                           pulls (Interface Control bit 7), RESETB synchronizer, NAND tree
└── usb_ulpi_phy_top
usb_ulpi_phy_top            phy_if + register file; maps comparators -> VbusState,
│                           XcvrSelect -> TX speed, OpMode 10 -> bypass (no stuff/NRZI)
├── usb_ulpi_reg_file       the only register file: immediate set, mirrored at ext 00h-3Fh; IE masks
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

RX datapath (standalone for now, drives the `rx_*` inputs of `usb_ulpi_rx_path`):

```
usb_rx_datapath             mode select (XcvrSelect), local-TX hold-off, output stage (one event per ce60 tick)
├── usb_rx_hs_frontend      HS: captures CDR data on clk_rx, syncs squelch / CDR lock / enable
├── usb_rx_decoder (HS=1)   on clk_rx
├── usb_rx_elastic_buffer   ASYNC=1, clk_rx -> clk_bit, 16 events
├── usb_rx_fsls_frontend    FS/LS: syncs D+/D-/rxrcv, DPLL (40x / 320x oversampling on clk_bit)
├── usb_rx_decoder (HS=0)   on clk_bit
└── usb_rx_elastic_buffer   ASYNC=0, 4 events
usb_rx_decoder: usb_rx_nrzi_decoder -> usb_rx_sync_detect -> usb_rx_bit_unstuffer
                -> usb_rx_deserializer -> usb_rx_eop_check (START / BYTE / END(err) event words)
```

`BBSUD8F.v` is the X-FAB xh018 pad cell, copied unchanged from `IO_CELLS_JIF3V.v`. It needs `VLG_PRIMITIVES.v` (UDPs) and only models its pulls with `` `define DISPLAY_PD_PU_EN``. EN is active low. Pull-up is PUEN = 0, pull-down is PUEN = 1 with PDEN = 0. Do not edit the vendor files, and never commit them: `BBSUD8F.v`, `VLG_PRIMITIVES.v` and `IO_CELLS_JIF3V.v` are confidential X-FAB PDK data, the GitHub repo is public, and `.gitignore` lists them.

`usb_ulpi_tx_top` is an older, smaller top level: capture + TX datapath + bus owner, with no register access. Its register and RX hooks are left as open ports. `tb_usb_ulpi_tx_top` still tests it.

### Rules that hold across all files

- **One clock** (one exception, below). Everything runs on `clk_bit` (480 MHz). The 60 MHz ULPI domain is the clock enable `ce60`: high for one `clk_bit` cycle in eight, aligned with clk60. Logic in the ULPI domain must update only on `ce60` (some submodules call the port `ce`). Signals in that domain are 8-cycle multicycle paths. Active-low async reset is `rst_n`.
- **The exception: `clk_rx`**, the clock recovered by the HS CDR (assumption D1 in WORK_PLAN.md). Only `usb_rx_hs_frontend`, the HS `usb_rx_decoder` and the write side of the HS `usb_rx_elastic_buffer` run on it; the elastic buffer (Gray pointers) is the only crossing. `usb_rx_datapath` synchronizes the reset release for it. FS/LS receive is recovered digitally on `clk_bit` (assumption D2).
- **Speed encoding** is ULPI XcvrSelect everywhere: `00` HS, `01` FS, `10` LS, `11` sent at FS rate (LS-via-FS-preamble is not implemented). Speed is sampled at packet start. FS/LS bit rates come from the `FS_DIV=40` / `LS_DIV=320` dividers on `clk_bit`, and `DIV_W` sets the counter width.
- **Line encoding:** `txd` J = 1 / K = 0, LSB first. HS EOP is 8 bit times at the inverted level. FS/LS EOP is SE0 for 2 bits (`tx_se0`), then J for 1. In HS the serializer needs a word every `ce60`. If one is missing, the packet ends with an EOP and `tx_underrun` pulses.
- **Keeping TX and register transfers apart** (see `usb_ulpi_core.v` header): a register command is not acknowledged while `usb_tx_holding` is busy. TXCMD decode is inhibited while `reg_link_busy` is set, because payload, address and data bytes can look like commands. The bus owner never takes the bus while either transfer is active. Between the acknowledge of a register read and its data (`rd_pend` from reg_access), `usb_ulpi_burst_mux` starts no PHY burst, so the read data is the first byte after the turnaround and never trails an RXCMD. Keep these interlocks when changing capture, holding, reg_access or bus_owner.
- **Bit stuffing:** the counter restarts at each packet, and SYNC goes through as ordinary data. A stuff bit is still inserted when six 1s end the packet. On RX the unstuffer loads its run counter with 1 on the final 1 of SYNC, to match.
- **RX framing:** HS EOP = bit-stuff violation with exactly 7 residual bits; FS/LS EOP = SE0 bit with 0 residual bits; anything else ends the packet with `rx_error`. SYNC detection needs `HS_ZMIN=6` / `FS_ZMIN=4` zeros before the final 1, and after a packet it only rearms on SE0 or when the HS receiver goes inactive (squelch), so data that looks like SYNC never starts a packet.
- **Not implemented yet** (exported only, no logic reacts to them): OpMode `01`/`11` driver disable, `soft_reset`, SuspendM / low-power (`dir_hold` is an input from the future low-power controller). The line-state, VBUS and ID detectors and the AFE are also outside this repo.

### Testbench style

The integration testbenches model a ULPI Link at the pins. The model holds each byte until NXT, retries a command when it loses to DIR, and flags protocol errors. They check register contents against a shadow model and rebuild every TX packet from `txd`/`tx_en`/`tx_se0` (de-NRZI, de-stuff, EOP timing). Register data deliberately uses bytes that look like commands (40h, 4Fh, 80h, AFh, C0h, EFh, 2Fh). New testbenches should follow the same pattern: an `errors` counter, the `TEST PASSED`/`TEST FAILED` line, a timeout watchdog and a VCD dump.

Each module's header comment holds its detailed spec (pipeline position, timing, corner cases). Read it before you edit the module, and keep it up to date.
