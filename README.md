# FPGA_AMWaveSynth
Vy first feasibility test of AMWaveSynth (https://github.com/radiolab81/AMWaveSynth) in verilog

![alt text](https://github.com/radiolab81/FPGA_AMWaveSynth/blob/main/www/1.png "Logo Title Text 1")

![alt text](https://github.com/radiolab81/FPGA_AMWaveSynth/blob/main/www/2.png "Logo Title Text 1")

The consumption of LUTs and HW multipliers is very manageable in this 4 channel version, so that even on very old and inexpensive FPGAs, like the Cyclone II series, many more NCO instances can run.

```
Top-level Entity Name	am_modulator_top
Family	Cyclone II
Device	EP2C5T144C8
Timing Models	Final
Total logic elements	557 / 4,608 ( 12 % )
Total combinational functions	460 / 4,608 ( 10 % )
Dedicated logic registers	415 / 4,608 ( 9 % )
Total registers	415
Total pins	20 / 89 ( 22 % )
Total virtual pins	0
Total memory bits	32,768 / 119,808 ( 27 % )
Embedded Multiplier 9-bit elements	8 / 26 ( 31 % )
Total PLLs	0 / 2 ( 0 % )
```

Estimation: 
- 12-13 channels on ancient EP2C5 without techniques such as time multiplexing are no problem, 16-24 AM stations using time-multiplexing without special tricks, with further optimizations, of course, even more
- Contemporary FPGAs in the hobby sector such as Tang Nano 25k, 50-60 AM stations without effort, using time-multiplexing 200+ AM stations, more than a complete long- and medium-wave band together!

Good prerequisites for realizing the AMWaveSynth as an FPGA chip, in addition to the existing software version.

## Update 10ch tech-demo: 
---


![att](https://github.com/radiolab81/FPGA_AMWaveSynth/blob/main/www/10ch_with_att.jpg "first 3 stations with att.")

# Hardened MCU-to-FPGA Receiver (EMC-Proof Version)

This Verilog module is a robust, hardware-hardened communication interface designed to bridge the gap between an asynchronous MCU (like ESP32, STM32, or AVR) and internal FPGA logic. 

Unlike standard RTL receivers, this "EMC-Version" is specifically engineered to handle **real-world physical connections** such as long jumper wires, unshielded breadboards, and environments with high electromagnetic interference (EMI).

## 🚀 Key Features

* **EMC-Hardened Input Stage:**
    * **3-Stage Synchronizer:** Eliminates metastability issues on the asynchronous `data_en` strobe.
    * **Digital Glitch Filter:** A 4-tap integrator logic ignores high-frequency spikes and crosstalk on the signal lines.
    * **Schmitt-Trigger Logic:** Implements digital hysteresis to ensure clean state transitions.
* **FSM Watchdog Timer:** An integrated hardware watchdog automatically resets the Finite State Machine to the `IDLE` state if a transmission is interrupted or corrupted by noise, preventing system deadlocks.
* **Safe Data Latching:** 2-FF staging for the 8-bit data bus ensures consistent data capturing across the clock domain boundary.
* **High Reliability Protocol:** Supports robust command headers for Audio, Frequency, and Gain control.

## 🛠 Hardware Architecture

The module implements a multi-layer defense strategy for incoming signals:

1.  **Synchronization Layer:** All asynchronous inputs are brought into the local `clk` domain.
2.  **Filter Layer:** The `data_en` strobe must be stable for a programmable number of clock cycles (`FILTER_TAPS`) before being recognized as a valid edge.
3.  **Watchdog Layer:** Tracks FSM activity and triggers a timeout if the MCU stops sending bytes mid-packet.

## 📋 Module Parameters

| Parameter | Default Value | Description |
|:--- |:--- |:--- |
| `TIMEOUT_CYCLES` | `32'd50_000_000` | FSM Reset timeout (e.g., 1.0s @ 50MHz). |
| `FILTER_TAPS` | `4'd4` | Number of stable clock cycles required to validate a strobe. |

## 📡 Protocol Specification

The module listens for a 3-character ASCII header followed by a fixed-length payload:

### 1. Audio Stream (`AUD`)
Updates 10 channels of 8-bit PCM data.
* **Header:** `0x41 0x55 0x44` ("AUD")
* **Payload:** 10 Bytes (CH0 to CH9)

### 2. Frequency Control (`FRQ`)
Updates 32-bit Phase Increments (NCO) for 10 channels.
* **Header:** `0x46 0x52 0x51` ("FRQ")
* **Payload:** 40 Bytes (10x 4-Byte words, Big-Endian)

### 3. Gain Control (`GAN`)
Updates 16-bit volume/gain for a specific channel.
* **Header:** `0x47 0x41 0x4E` ("GAN")
* **Payload:** 1 Byte (Channel ID 0-9) + 2 Bytes (16-bit Gain, MSB first)

## 💻 Timing Requirements (Real-World)

Due to the internal glitch filtering, the MCU must hold the `data_en` signal high for several FPGA clock cycles. 

**Minimum Pulse Width Calculation:**
$$T_{pulse} > (FILTER\_TAPS + 4) \times T_{clk}$$

For a 50 MHz FPGA clock and `FILTER_TAPS = 4`, the MCU should hold the Strobe/Enable signal for at least **160-200 ns** to ensure 100% reliable detection.

## 📥 Implementation Example (Verilog)

```verilog
mcu_rx #(
    .TIMEOUT_CYCLES(50_000_000), // 1 second @ 50MHz
    .FILTER_TAPS(4)              // Aggressive glitch filtering
) u_receiver (
    .clk(hw_clk),
    .rst(sys_rst),
    .data_in(mcu_bus_8bit),
    .data_en(mcu_strobe_pin),
    // ... outputs
);
```

## Still to do:
 * A more or less generalized `mcu_tx` demo for ESP32 :white_check_mark: , STM32, and similar MCUs; perhaps a softcore version as well.
 * Direct Ethernet support (without need for external mcu), W5100 / W5500 or similar
 * Evaluation of performance across multiple FPGA development boards
 * Recording of RF data to SD or USB mass media, directly on the board
 * Sferics emulation
 * ...
 * Documentation and complete redesign of this site
