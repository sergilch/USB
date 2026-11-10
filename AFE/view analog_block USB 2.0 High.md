# Description of the Developed USB 2.0 High-Speed Functional Blocks

## 1. General Overview

This document describes three functional blocks developed for a USB 2.0 High-Speed interface:

1. USB 2.0 High-Speed RX block (receiver).
2. USB 2.0 High-Speed TX block (transmitter).
3. Clock and Data Recovery (CDR) system with an auxiliary Phase-Locked Loop (PLL).

The RX and TX blocks operate with differential signals and use a supply voltage of 3.3 V. The CDR block uses a supply voltage of 1.8 V and includes two interconnected control loops.

To distinguish signals belonging to different blocks, their names are prefixed as follows:

- `RX_` — receiver signals.
- `TX_` — transmitter signals.
- `CDR_` — clock and data recovery signals.

---

## 2. USB 2.0 High-Speed RX Block (Receiver)

### 2.1. General Overview

The RX block is a CMOS transistor-based analog signal processing circuit designed for differential signal reception.

The circuit features a symmetrical architecture and consists of:

- An input differential stage.
- Transistor-based signal processing stages.
- A reference voltage generation network.
- Output inverting buffers.

The primary function of the circuit is to process two differential input signals, `RX_IN_P` and `RX_IN_N`, and generate the corresponding output signals, `RX_OUT_P` and `RX_OUT_N`.

The circuit represents the USB3320 input receiver stage, implemented using CMOS transistors and based on the Schmitt trigger principle.

### 2.2. Main Functional Blocks

#### 2.2.1. Input Differential Stage

The input stage is designed to receive and process differential signals:

- `RX_IN_P` — positive input signal.
- `RX_IN_N` — negative input signal.

The input signals are applied to the gate terminals of MOS transistors in the central part of the circuit.

The differential structure compares the input voltage levels and generates corresponding voltage variations at the internal nodes of the circuit.

#### 2.2.2. Reference Voltage Generation Network

The central part of the circuit contains a reference voltage network connected to `RX_VREF` and consisting of two resistors:

- `RX_R0`
- `RX_R1`

These resistors form a resistive network associated with the reference voltage. The network contributes to establishing the operating voltages at the internal circuit nodes.

Its purpose is to provide a reference level for input signal processing and help define the switching thresholds.

#### 2.2.3. Transistor-Based Signal Processing Stages

The main part of the circuit is implemented using MOS transistors arranged symmetrically around the input paths.

The transistor groups perform the following functions:

- Generating currents in the differential branches.
- Amplifying voltage variations caused by changes in the input signals.
- Establishing the required operating conditions for the internal stages.
- Generating signals for the subsequent output stages.

The symmetrical arrangement of the transistor branches ensures coordinated operation of the positive and negative signal paths.

#### 2.2.4. Power Supply Networks

The circuit uses two main power supply rails:

- `RX_VDD` — positive supply voltage.
- `RX_GND` — ground reference.

The supply rails are connected to the corresponding transistor stages and inverting elements.

They provide the required operating conditions for the MOS transistors and CMOS logic buffers.

The RX block supply voltage is 3.3 V.

#### 2.2.5. Output Inverting Stages

The upper part of the circuit contains a series connection of two inverters that generates the `RX_OUT_P` output.

The lower part contains an equivalent two-inverter chain that generates the `RX_OUT_N` output.

The output inverters perform the following functions:

- Restoring logic levels.
- Increasing output drive capability.
- Providing the required output signal polarity.
- Isolating the internal analog circuitry from the external load.

Using two cascaded inverters preserves the original signal polarity relative to the input of the first inverter.

### 2.3. Circuit Operating Principle

The circuit operates as follows:

1. Differential input signals are applied to `RX_IN_P` and `RX_IN_N`.
2. The input transistor stage responds to the voltage difference between the two inputs.
3. Changes in the differential input voltage cause current redistribution between the transistor branches.
4. The internal transistor stages amplify the resulting voltage variations.
5. The resistor network consisting of `RX_R0` and `RX_R1` contributes to establishing the reference operating levels.
6. The resulting internal signals are applied to the output inverting stages.
7. The corresponding output signals are generated at `RX_OUT_P` and `RX_OUT_N`.

The circuit therefore converts differential input signals into corresponding output signals using transistor-based processing stages and CMOS inverters.

### 2.4. Main Signals and Components

| Designation | Description |

| `RX_IN_P` | Positive input signal |
| `RX_IN_N` | Negative input signal |
| `RX_OUT_P` | Positive output signal |
| `RX_OUT_N` | Negative output signal |
| `RX_VREF` | Reference voltage |
| `RX_VDD` | Positive supply voltage |
| `RX_GND` | Ground |
| `RX_R0`, `RX_R1` | Reference voltage network resistors |
| MOS transistors | Signal amplification, switching, and current generation |
| CMOS inverters | Output signal conditioning and buffering |

### 2.5. Operating Principle of the Schmitt Trigger

The circuit uses the Schmitt trigger principle, where positive feedback provides hysteresis between the switching thresholds.

This improves noise immunity and prevents unwanted output transitions caused by small input voltage fluctuations.

The circuit should therefore be classified as a differential Schmitt trigger receiver rather than a conventional differential amplifier.

### 2.6. Additional Notes

This description is based on the circuit topology shown in the schematic.

Accurate identification of individual transistor operating modes, voltage gain, switching thresholds, and the functions of specific transistor groups requires a detailed schematic and the electrical parameters of the MOS transistors.

### 2.7. Key Functional Features

- Differential USB input signal reception.
- Schmitt trigger-based signal detection.
- Hysteresis generation through positive feedback.
- Improved immunity to input noise and interference.
- CMOS logic-level restoration.
- Differential output signal generation at `RX_OUT_P` and `RX_OUT_N`.

### 2.8. Main Electrical Characteristics

| Parameter | Value |

| Circuit type | CMOS differential receiver |
| Application | USB 2.0 High-Speed Receiver |
| Input signal type | Differential |
| Number of signal inputs | 2 |
| Number of signal outputs | 2 |
| Reference voltage | `RX_VREF` |
| Reference network | `RX_R0`, `RX_R1` |
| Output stage | CMOS inverters |
| Main supply voltage | 3.3 V |

---

## 3. USB 2.0 High-Speed TX Block (Transmitter)

### 3.1. Circuit Purpose

The TX block is an analog CMOS transmitter with differential inputs and outputs, designed to generate high-speed signals for the USB 2.0 High-Speed interface.

Its primary function is to receive differential input signals `TX_IN_P` and `TX_IN_N`, process them through transistor stages, and generate output signals `TX_OUT_P` and `TX_OUT_N` for transmission over the USB differential line.

The circuit architecture includes:

- Input transistor stages.
- Differential amplifier stages.
- Bias current generation circuits.
- Control transistor switches.
- Differential output driver.
- External capacitor connection nodes `TX_CAP_P` and `TX_CAP_N`.

The circuit is implemented using CMOS transistors and includes dedicated bias current generation and operating mode control circuits.

### 3.2. Input Characteristics

The schematic includes the following input signals and control connections:

| Designation | Description |

| `TX_VDD` | CMOS stage supply voltage |
| `TX_GND` | Ground reference, 0 V |
| `TX_EN` | Transmitter enable signal |
| `TX_I_5U` | Operating mode selection control signal |
| `TX_VREF` | Reference voltage for bias current generation |
| `TX_IN_P` | Positive differential input signal |
| `TX_IN_N` | Negative differential input signal |
| `TX_CAP_P` | Positive branch external capacitor connection |
| `TX_CAP_N` | Negative branch external capacitor connection |

#### 3.2.1. Differential Inputs

The input signals `TX_IN_P` and `TX_IN_N` form a differential pair.

The input stage receives the differential signal and converts it into control currents for the internal transistor stages.

#### 3.2.2. Control Inputs

- `TX_EN` is used to enable or disable the transmitter stage.
- `TX_I_5U` controls the internal operating mode of the circuit.
- `TX_VREF` provides a reference voltage for bias current generation and establishes the required transistor operating conditions.

### 3.3. Circuit Operating Principle

1. After the supply voltage `TX_VDD` is applied, the internal transistor circuits establish the required bias conditions.
2. When `TX_EN` is activated, the main functional stages of the transmitter are enabled.
3. The reference voltage `TX_VREF` is used to generate operating currents and establish transistor bias conditions. The control signal `TX_I_5U` participates in configuring the internal operating mode.
4. The input signals `TX_IN_P` and `TX_IN_N` are applied to the differential transistor stages.
5. The voltage difference between the input branches is converted into corresponding changes in transistor currents.
6. The processed signal is applied to the differential output driver, which generates `TX_OUT_P` and `TX_OUT_N`.
7. The output stage provides the required signal amplitude and electrical characteristics for USB 2.0 High-Speed data transmission.
8. External capacitors connected to `TX_CAP_P` and `TX_CAP_N` influence the dynamic characteristics of the output nodes.

### 3.4. Transmitter Output Characteristics

The circuit provides the following output signals:

- `TX_OUT_P` — positive branch of the differential output signal.
- `TX_OUT_N` — negative branch of the differential output signal.

The output stage is designed to generate a high-speed differential signal for USB 2.0 High-Speed transmission.

| Parameter | Value |

| Data transmission rate | 480 Mbps |
| Output high-level voltage | 360–440 mV |

### 3.5. Main Electrical Characteristics

| Parameter | Value |

| Circuit type | Analog CMOS transmitter |
| Application | USB 2.0 High-Speed Transmitter |
| Input signal type | Differential |
| Number of signal inputs | 2 |
| Number of signal outputs | 2 |
| Enable control | `TX_EN` |
| Additional control signal | `TX_I_5U` |
| Reference voltage | `TX_VREF` |
| Logic supply voltage | `TX_VDD` |
| Ground reference | `TX_GND` |
| Capacitive connection nodes | `TX_CAP_P`, `TX_CAP_N` |
| Output signal type | Differential |
| Maximum data rate in HS mode | 480 Mbps |
| Main supply voltage | 3.3 V |

### 3.6. Power Supply

The transmitter uses the following power supply connections:

- `TX_VDD` — positive supply voltage.
- `TX_GND` — ground reference.

The main supply voltage of the TX block is 3.3 V.

### 3.7. Control and Bias Circuits

The internal transistor stages provide bias current generation and voltage biasing.

The `TX_EN` and `TX_I_5U` control inputs define the operating mode of the circuit, while `TX_VREF` establishes the reference level for bias current generation.

### 3.8. Output Stage

The output stage generates differential signals `TX_OUT_P` and `TX_OUT_N` for high-speed USB data transmission.

External capacitors connected to `TX_CAP_P` and `TX_CAP_N` influence the dynamic characteristics of the output nodes.

### 3.9. Conclusion

The circuit is an analog CMOS transmitter with a differential architecture, designed to generate output signals for the USB 2.0 High-Speed interface.

The internal transistor stages provide bias current generation, voltage biasing, and differential input signal processing.

The `TX_EN` and `TX_I_5U` control inputs define the operating mode of the circuit, while `TX_VREF` establishes the reference level.

The output stage generates differential signals `TX_OUT_P` and `TX_OUT_N` for high-speed USB data transmission.

---

## 4. CDR Block (Clock and Data Recovery)

### 4.1. General Overview

The CDR block is a Clock and Data Recovery system that uses an auxiliary Phase-Locked Loop (PLL) to stabilize its operation.

The schematic can be divided into two parallel loops:

1. Lower loop — reference PLL / frequency synthesizer.
2. Upper loop — CDR (Clock and Data Recovery).

The lower loop generates a stable reference frequency, while the upper loop extracts the clock signal from the incoming data stream.

The CDR block operates from a 1.8 V supply voltage.

### 4.2. Lower Loop: Reference PLL / Frequency Synthesizer

The lower loop is responsible for generating a stable reference frequency that is a multiple of the input frequency `CDR_FREF`.

Its main elements are:

- `CDR_FREF` — reference frequency input.
- PFD_v1 — phase-frequency detector that compares the reference frequency and the feedback frequency.
- Charge Pump — converts the UP/DN signals into current.
- Filter (`CDR_R2`, `CDR_C3`, `CDR_C4`) — passive low-pass loop filter that generates the control voltage `CDR_CH_OUT_PLL`.
- Ring VCO — voltage-controlled ring oscillator. Its frequency depends on the voltage at the `CDR_V_IN` input.
- Inverter chain (`CDR_INV1`, `CDR_INV3`) — buffer stages for signal amplification.
- `CDR_DIVIDE_20` — divide-by-20 frequency divider. It divides the VCO output frequency and feeds it back to the Fvco input of the PFD, closing the feedback loop.

The lower PLL locks to the reference frequency and generates a VCO frequency that is 20 times higher than the reference frequency:

\[
f_{\mathrm{VCO}} = 20 \cdot f_{\mathrm{REF}}
\]

### 4.3. Upper Loop: CDR — Clock and Data Recovery

The upper loop is designed to extract the clock signal from the incoming data stream `CDR_DATA`.

Its main elements are:

- `CDR_DATA` — incoming data signal.
- Clock-data recovery_v2 — phase detector block (Alexander phase detector). It compares the phase of the incoming data with the clock signal and generates UP/DN signals.
- Charge Pump — converts the UP/DN signals into current.
- Filter (`CDR_R8`, `CDR_C2`, `CDR_C1`) — loop filter that generates the control voltage `CDR_CH_OUT`.
- Ring VCO — oscillator that generates the recovered clock frequency.
- Inverter chain (`CDR_INV1`, `CDR_INV3`, `CDR_INV5`) — output buffer.

The signal from the last inverter goes to the output. The signal from the intermediate inverter (`CDR_INV3`, labeled 17) is fed back to the CLK input of the data recovery block, closing the CDR loop.

### 4.4. Interaction Between the Two Loops

There is a crucial connection between the two loops.

A vertical connection runs from the `CDR_CH_OUT_PLL` node, which is the control voltage of the lower PLL, to the `CDR_V_IN_2` input of the upper Ring VCO.

This is a PLL-assisted CDR architecture.

The lower PLL locks to the reference frequency `CDR_FREF` and multiplies it. Based on the divide-by-20 feedback divider, the VCO frequency is 20 times higher than the reference frequency.

The control voltage of the lower PLL (`CDR_CH_OUT_PLL`) is fed to the coarse-tuning input (`CDR_V_IN_2`) of the upper oscillator. This keeps the CDR oscillator frequency approximately within the required range, near the data rate frequency.

The upper loop then performs fine phase tuning through its own filter and control path:

`CDR_CH_OUT` → `CDR_V_IN`

This allows the clock edge to be aligned with the middle of the data bit (the center of the eye diagram).

The auxiliary PLL significantly accelerates the lock time and improves overall system reliability.

### 4.5. Main Signals and Components

| Designation | Description |

| `CDR_FREF` | Reference frequency input |
| `CDR_DATA` | Incoming data signal |
| `CDR_CH_OUT_PLL` | Lower PLL loop filter output |
| `CDR_CH_OUT` | Upper CDR loop filter output |
| `CDR_V_IN_2` | Coarse-tuning input of the upper Ring VCO |
| `CDR_V_IN` | VCO control input |
| `CDR_DIVIDE_20` | Divide-by-20 frequency divider |
| `CDR_INV1`, `CDR_INV3` | Lower-loop inverter chain |
| `CDR_INV1`, `CDR_INV3`, `CDR_INV5` | Upper-loop inverter chain |
| `CDR_R2`, `CDR_C3`, `CDR_C4` | Lower PLL loop filter components |
| `CDR_R8`, `CDR_C2`, `CDR_C1` | Upper CDR loop filter components |

### 4.6. Power Supply

The CDR block uses a supply voltage of 1.8 V.

The supply rails provide the required operating conditions for the phase detectors, charge pumps, loop filters, voltage-controlled oscillators, and inverter stages.

### 4.7. Conclusion

The CDR block is a high-speed data receiver system in which the clock frequency is recovered directly from the incoming data stream and stabilized using an external reference frequency through an auxiliary PLL.

The lower PLL provides coarse frequency tuning, while the upper CDR loop performs fine phase alignment.

This architecture improves the frequency acquisition process and overall system reliability.

---

## 5. Comparison of Functional Blocks

### 5.1. Main Differences

| Parameter | RX Block | TX Block | CDR Block |

| Functional purpose | Differential signal reception | Differential signal transmission | Clock and data recovery |
| Main architecture | CMOS differential receiver | Analog CMOS transmitter | Two interconnected PLL/CDR loops |
| Input signals | `RX_IN_P`, `RX_IN_N` | `TX_IN_P`, `TX_IN_N` | `CDR_DATA`, `CDR_FREF` |
| Output signals | `RX_OUT_P`, `RX_OUT_N` | `TX_OUT_P`, `TX_OUT_N` | Recovered clock signal |
| Main functional elements | Differential transistor stages, Schmitt trigger, CMOS inverters | Differential transistor stages, bias circuits, output driver | Phase detectors, charge pumps, loop filters, Ring VCOs |
| Main control signals | `RX_VREF` | `TX_EN`, `TX_I_5U`, `TX_VREF` | `CDR_CH_OUT_PLL`, `CDR_CH_OUT` |
| Supply voltage | 3.3 V | 3.3 V | 1.8 V |
| Main function | Input signal detection and logic-level restoration | Generation of high-speed differential output signals | Recovery and stabilization of the clock signal |

### 5.2. Functional Differences

The RX block receives differential signals and converts them into corresponding output signals. Its Schmitt trigger structure provides hysteresis and improves immunity to input noise.

The TX block processes differential input signals and generates high-speed differential output signals. Its internal bias circuits and control inputs establish the required operating conditions for the transmitter stages.

The CDR block recovers the clock signal from the incoming data stream. Its auxiliary PLL provides coarse frequency tuning, while the upper CDR loop performs fine phase adjustment.

---

## 6. Conclusion

The three developed blocks perform complementary functions within a USB 2.0 High-Speed interface.

The RX block provides differential signal reception and logic-level restoration using a Schmitt trigger-based architecture.

The TX block generates differential output signals for USB 2.0 High-Speed data transmission at a data rate of 480 Mbps.

The CDR block recovers the clock signal from the incoming data stream and uses an auxiliary PLL to stabilize the oscillator frequency and improve the clock recovery process.

The RX and TX blocks use a 3.3 V supply voltage, while the CDR block operates from a 1.8 V supply voltage.

Together, these blocks implement the main analog functions required for high-speed USB data reception, transmission, and clock recovery.
