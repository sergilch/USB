# USB 2.0 PHY (HS/FS/LS) – Digital Part with ULPI Interface

*Text description of `usb_phy_ulpi_digital.drawio` (diagram title: "USB 2.0 PHY (HS/FS/LS) - Digital Part with ULPI Interface (reference: USB3320)").*

---

## 1. What the diagram represents

The file is a **block diagram** (a data/control-flow diagram rather than a decision flowchart) of a **USB 2.0 physical layer (PHY)** that supports High-Speed (480 Mbps), Full-Speed (12 Mbps) and Low-Speed (1.5 Mbps) operation. The design is modelled on the Microchip **USB3320** PHY.

It shows how the **digital part** of the PHY is organised and how it connects to:

- the **ULPI link side** (an SoC, FPGA or USB controller) on the left,
- the **system** (reference clock and reset) at the bottom left,
- the **analog front end (AFE)** on the right, which is labelled "already in development" and is therefore treated as a given,
- the **USB connector** (D+/D−, VBUS, ID) at the far right.

The central idea: the PHY translates between two worlds.

- **Link side:** byte-wide, parallel ULPI transactions at 60 MHz.
- **Wire side:** a serial, bit-stuffed, NRZI-encoded differential signal on D+/D−.

### Regions and colour code

| Region / colour | Meaning |
|---|---|
| Blue dashed box, "DIGITAL CORE" | All digital logic. VDD18 supply domain. Contains two clock domains: `clk60` (ULPI domain) and `clk_bit` (clock recovered by the CDR). |
| Red dashed box, "AFE (analog)" | Analog blocks (drivers, receivers, PLL/CDR, terminations, VBUS/ID comparators, 1.8 V regulator). |
| Blue blocks | ULPI interface controller |
| Green blocks | Transmit (TX) path |
| Yellow blocks | Receive (RX) path |
| Purple blocks | Control and status blocks |
| Grey blocks / bars | External entities and the two internal buses |

---

## 2. Components (nodes)

### 2.1 External entities (outside both dashed boxes)

| Node | Description |
|---|---|
| **ULPI Link** | The SoC / FPGA / USB controller that talks to the PHY over ULPI. |
| **System** | Provides `REFCLK` (19.2 / 24 / 26 MHz) and `RESETB`. |
| **DP / DN** | USB connector data pins D+ / D−. |
| **VBUS / ID** | USB connector power and ID pins (used for OTG). |

### 2.2 Digital core

**Interface**

| Node | Function |
|---|---|
| **ULPI Interface Controller** | 8-bit SDR interface at 60 MHz. Implements the DIR / NXT / STP handshake and bus turnaround (TX/RX). Decodes TXCMD (NOPID / PID), generates RXCMD (LineState, VbusState, RxActive, RxError, ID), runs the register read/write FSM and handles STP aborts. |

**Transmit path (green, flows left → right across the top row)**

| Node | Function |
|---|---|
| **TX Holding Reg / Ctrl** | Holds the TXCMD payload and paces data using NXT. |
| **SYNC + PID/Data Mux** | Prepends the SYNC pattern (speed-dependent) and multiplexes in PID and data bytes. |
| **Bit Stuffer** | Inserts a 0 after six consecutive 1s (USB bit stuffing). |
| **NRZI Encoder** | Line encoding. Bypassed in chirp and test modes. |
| **Serializer 8:1 + EOP Gen** | Converts bytes to a serial stream at 480 / 12 / 1.5 Mbps and generates the SE0 end-of-packet. |

**Receive path (yellow, flows right → left in the second row)**

| Node | Function |
|---|---|
| **SYNC Detect + Deserializer 1:8** | Detects SYNC, achieves bit/byte alignment, converts serial bits to bytes. |
| **NRZI Decoder** | Reverses NRZI encoding. |
| **Bit Unstuffer** | Removes stuffed bits and detects stuff errors. |
| **EOP Detect + RxError Check** | Detects end of packet, drives the RxActive framing and flags errors. |
| **Elastic Buffer (CDC) + RXCMD Mux** | Crosses data from `clk_bit` to `clk60` and merges data bytes with RXCMD status bytes. |

**Control and status blocks (purple)**

| Node | Function |
|---|---|
| **ULPI Register File** | Standard ULPI registers: VID/PID (00h–03h), Function Control (04h), Interface Control (07h), OTG Control (0Ah), USB Interrupt Enable Rising/Falling (0Dh/10h), Interrupt Status (13h), Interrupt Latch (14h), Debug (15h), Scratch (16h), Set/Clear aliases and extended access (2Fh). |
| **Mode / Termination Control** | Decodes XcvrSelect[1:0], TermSelect, OpMode[1:0], SuspendM and Reset. Drives the D+ 1.5 kΩ pull-up, HS termination and pull-downs, and selects speed. |
| **HS Handshake / Chirp FSM** | High-speed negotiation: device chirp-K, KJKJKJ detection, HS detect, SE0 reset detect, suspend/resume, remote wakeup. |
| **OTG / VBUS Control** | ID pull-up, DrvVbus, VBUS charge/discharge, and the SessValid / SessEnd / VbusValid / IdGnd status. |
| **Line State / Event Detector** | Synchronises and debounces LineState[1:0], handles squelch, HS disconnect, RxActive/RxError and HostDisconnect, reporting to RXCMD and interrupts. |
| **Clock / Reset / Power Mgmt** | REFCLK selection, PLL enable and lock wait, 60 MHz CLKOUT, clock gating in suspend, POR and reset synchronisation, power-good. |
| **DFT / Test Modes** | USB-IF test modes (Test_J, Test_K, Test_SE0_NAK, Test_Packet), digital loopback, scan, BIST. |

**Buses (grey bars)**

| Node | Function |
|---|---|
| **DATAPATH CONTROL / EVENT BUS** | Carries OpMode, XcvrSelect, TermSelect, speed and enables down to TX/RX, and carries LineState, VbusState, RxActive, RxError, HostDisconnect and IdGnd up to the RXCMD generator. |
| **CONFIG / STATUS BUS** | Links the register file and all control blocks to each other and to the AFE interface (XcvrSelect, TermSelect, OpMode, pull-up/down enables, VBUS comparators, IdGnd, …). |

**Digital/analog boundary**

| Node | Function |
|---|---|
| **AFE INTERFACE** | Synchronisers and glitch filters for analog status, level shifters / isolation cells, trim and enable registers, reset synchronisation, PLL/CDR control and lock status. |

### 2.3 Analog front end (AFE)

| Node | Function |
|---|---|
| **Transmitter** | HS current-mode driver, FS/LS driver, slew-rate control. |
| **PLL + CDR** | Generates the 480 MHz bit clock and 60 MHz `clk60`; recovers data and clock from the received stream. |
| **Receiver** | HS differential receiver, squelch and disconnect comparators, FS/LS differential and single-ended (DP, DN) receivers. |
| **Termination / Pull Resistors** | Switchable 1.5 kΩ D+/D− pull-up, HS 45 Ω terminations, 15 kΩ pull-downs. |
| **VBUS Comparators / ID Detect** | OTG-related, optional. |
| **1.8 V Regulator** | Supplies the digital core (VDD18). |

---

## 3. Connections and their purpose

### 3.1 ULPI link ↔ PHY (the parallel interface)

| Connection | Direction | Purpose |
|---|---|---|
| `CLKOUT` (60 MHz) | PHY → Link | The PHY is the clock master; all ULPI signals are synchronous to it. |
| `DIR` | PHY → Link | Tells the link who owns the data bus (turnaround control). |
| `NXT` | PHY → Link | Flow control: the PHY accepts the next TX byte, or signals an RX data byte is valid. |
| `STP` | Link → PHY | Ends a transmit packet or aborts an operation. |
| `DATA[7:0]` | Bidirectional | 8-bit data bus carrying TXCMD/data, RXCMD/data and register accesses. |

### 3.2 System → PHY

- `REFCLK, RESETB` go from **System** to **Clock / Reset / Power Mgmt**. The block uses them to start the PLL, generate `clk60` and bring the design out of reset in a controlled way.

### 3.3 Transmit data path (link → wire)

`ULPI Controller → TX Holding Reg → SYNC + PID/Data Mux → Bit Stuffer → NRZI Encoder → Serializer + EOP Gen → Transmitter (AFE) → DP/DN`

- The first hop carries `TXCMD + DATA`.
- The last digital hop to the AFE carries `TXD, TX_EN, TX_SE0` and speed/mode information.
- **Purpose:** turn link-side bytes into a valid USB bit stream (SYNC, bit stuffing, NRZI, EOP) at the selected speed.

### 3.4 Receive data path (wire → link)

`DP/DN → Receiver (AFE) → PLL + CDR → SYNC Detect + Deserializer → NRZI Decoder → Bit Unstuffer → EOP Detect + RxError Check → Elastic Buffer + RXCMD Mux → ULPI Controller → Link`

- The Receiver passes serial data to the CDR, which returns retimed `RXD` and `clk_bit` to the digital RX chain.
- The Elastic Buffer is the **clock-domain crossing** from `clk_bit` to `clk60`.
- The final hop to the ULPI controller carries `RXD/RXCMD`.
- **Purpose:** recover the clock and data, undo encoding and stuffing, detect packet boundaries and errors, and present data and status to the link in the ULPI domain.

### 3.5 Receiver → Line State / Event Detector

- Carries `RXDP, RXDM, RXRCV, SQUELCH, DISCONNECT`.
- **Purpose:** gives the digital side the raw line conditions so it can compute LineState, detect disconnects and resets, and feed the event bus.

### 3.6 Datapath control / event bus (dashed connections)

- **Inputs** (Mode/Termination Control, HS Handshake FSM, Line State Detector → bus): publish operating mode, speed and detected line events.
- **Outputs:** the bus goes to the **Serializer/EOP Gen** and the **SYNC Detect/Deserializer** (enabling and configuring TX/RX), and to the **ULPI Controller** (so it can build RXCMD bytes).
- **Purpose:** a shared "wiring harness" that avoids many point-to-point links between control logic and the datapath.

### 3.7 Config / status bus

- The **Register File, Mode/Term Control, HS FSM, OTG Control and Line State Detector** are bidirectionally attached; **DFT** attaches via a dashed "scan / test modes" link.
- The bus connects onward to the **AFE Interface**.
- **Purpose:** register values (written by the link) configure the PHY blocks and the analog side, and status flows back so it can be read or raised as interrupts. The **Register File ↔ ULPI Controller** link (`Reg R/W`) is how the link reads and writes those registers.

### 3.8 Clock / Reset / Power Mgmt ↔ AFE Interface

- Carries `REFCLK sel, PLL ctrl/lock, CLK60, resets` (bidirectional).
- **Purpose:** select the reference clock, enable the PLL, wait for lock, and distribute the resulting 60 MHz clock and synchronised resets.

### 3.9 AFE Interface ↔ analog blocks

| Connection | Signals | Purpose |
|---|---|---|
| AFE Interface ↔ PLL + CDR | `PLL_EN`, CDR control / lock | Turn the PLL/CDR on and read lock status. |
| AFE Interface → Termination / Pull Resistors | `DP_PULLUP_EN, HS_TERM_EN, PULLDOWN_EN` | Apply the correct terminations for the current speed/role (for example the FS pull-up for device attach, or HS termination after chirp). |
| AFE Interface ↔ VBUS / ID Detect | `VBUS/ID status, ID_PULLUP, DRVVBUS, CHRG/DISCHRG` | OTG control: drive VBUS and read session/ID status. |
| 1.8 V Regulator → AFE Interface | `VDD18, PWR_GOOD` | Supply the digital core and report that power is stable. |

The AFE Interface acts as the controlled **digital/analog boundary**: it synchronises and filters analog status and provides level shifting and isolation.

### 3.10 AFE ↔ USB connector

- **Transmitter → DP/DN:** drives the bus.
- **DP/DN → Receiver:** senses the bus.
- **Termination / Pull Resistors → DP/DN:** sets bus termination and pull-up/down state.
- **VBUS/ID Detect ↔ VBUS/ID pins** (bidirectional): measures and, in OTG mode, drives VBUS and senses ID.

---

## 4. Clock domains

- **`clk60`**: ULPI and digital-core domain. It comes from the PLL and is output as `CLKOUT`.
- **`clk_bit`**: clock recovered by the CDR from the incoming data, at 480 / 12 / 1.5 Mbps.
- The **Elastic Buffer** is the sole data crossing between them in the RX direction.

---

## 5. Summary

The diagram partitions a USB 2.0 PHY into:

1. a **parallel ULPI interface** toward the link,
2. a **TX pipeline** and **RX pipeline** performing USB serial framing, bit stuffing, NRZI coding and clock recovery,
3. a set of **control blocks** (registers, mode and termination, HS chirp handshake, OTG/VBUS, line-state detection, clock/reset, DFT) tied together by an **event bus** and a **config/status bus**,
4. an **AFE interface** that safely bridges to the **analog front end**, which finally connects to the USB connector pins.

Overall, the connections serve three purposes: **moving data** (TX/RX chains), **controlling behaviour** (mode, speed and termination via buses and registers), and **reporting state** (line state, VBUS/ID, errors and interrupts back to the link).
