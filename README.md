# FPGA_AMWaveSynth
Vy first feasibility test of AMWaveSynth (https://github.com/radiolab81/AMWaveSynth) in verilog ... soon / later ... perhaps ... maybe

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

# Communication Protocol: mcu_rx

The `mcu_rx` module implements a byte-oriented serial protocol to control 10 audio synthesis channels. Data transmission is state-managed via an 8-bit bus with a validation signal (`data_en`).

## General Packet Structure

Each command begins with a 3-byte ASCII header (identifier), followed by a specific number of data bytes. All multi-byte values are transmitted in **Big-Endian** format (MSB first).

| Command Type | Header | Data Length | Description |
| --- | --- | --- | --- |
| **Audio** | `AUD` | 10 Bytes | Updates 8-bit amplitude values for all channels. |
| **Frequency** | `FRQ` | 40 Bytes | Sets 32-bit frequency control words for all channels. |
| **Gain** | `GAN` | 3 Bytes | Sets the 16-bit volume for a specific channel. |

---

## Command Details

### 1. Audio Data (`AUD`)

Updates the instantaneous amplitude values (modulation signal) for channels 0 through 9.

* **Header:** `0x41 0x55 0x44` (ASCII "AUD")
* **Payload:** 10 Bytes (1 byte per channel)
* **Value Range:** `0x00` to `0xFF` (Offset-binary, midpoint = `0x80`)

**Sequence:**
`[A] [U] [D] [CH0] [CH1] [CH2] [CH3] [CH4] [CH5] [CH6] [CH7] [CH8] [CH9]`

---

### 2. Frequency Control (`FRQ`)

Sets the 32-bit phase increment values (Frequency Tuning Words) for all 10 channels.

* **Header:** `0x46 0x52 0x51` (ASCII "FRQ")
* **Payload:** 40 Bytes (4 bytes per channel, MSB first)

**Transmission Order:**

1. `f_ch0` (Bytes: MSB, Mid-H, Mid-L, LSB)
2. `f_ch1` (Bytes: MSB, Mid-H, Mid-L, LSB)
3. ... through `f_ch9`

---

### 3. Channel Gain (`GAN`)

Allows targeted att. adjustment for a single specific channel.

* **Header:** `0x47 0x41 0x4E` (ASCII "GAN")
* **Payload:** 3 Bytes
* **Byte 0:** Channel Index (`0x00` to `0x09`)
* **Byte 1:** Gain High-Byte (MSB)
* **Byte 2:** Gain Low-Byte (LSB)



**Value Range:** `0x0000` (Mute) -96dB att. to `0xFFFF` (Unity/Max Gain). 

---

## Technical Specifications

### Finite State Machine (FSM)

The module utilizes a state machine to decode incoming streams. Any invalid header character or out-of-range channel index results in an immediate transition back to `S_IDLE`.

### Reset Behavior

Upon a hardware reset (`rst`), the module initializes with the following defaults:

* **Audio:** All channels set to `0x80` (Neutral/Silent).
* **Frequency:** Channels are initialized with pre-defined hardcoded default frequencies.
* **Gain:** All channels set to maximum amplitude (`0xFFFF`).

### Interface Requirements

* **Clocking:** Data is sampled on the rising edge of `clk`.
* **Enable Signal:** The module performs edge detection on `data_en`. A single pulse per byte is required.
* **Endianness:** Big-Endian (MSB First) is strictly enforced for all multi-byte parameters.
