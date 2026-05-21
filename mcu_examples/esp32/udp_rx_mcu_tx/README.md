# 📻 ESP32 UDP-to-FPGA AM Radio Bridge

This project implements a hard real-time, ultra-low latency bridge between IP networks (Internet Radio) and an FPGA. It turns your ESP32 and FPGA into a multi-channel AM radio transmitter / modulator. 

The ESP32 receives in this tech-demonstration up to 10 independent audio streams via Wi-Fi (UDP), handles jitter buffering, and pushes the multiplexed audio alongside dynamic frequency and gain configuration to an FPGA via a high-speed 8-bit parallel bus. The FPGA can then use Numerically Controlled Oscillators (NCOs) to generate a genuine Medium Wave (AM) radio frequency spectrum. Depending on the FPGA used, several dozen virtual AM transmitters are possible — see the main page, section "Estimates."

## ✨ Features
* **Hard Real-Time Performance:** Audio streaming is pinned to Core 1, utilizing a precise 40µs hardware timer (25 kHz sample rate).
* **Bare-Metal GPIO:** Uses direct register access (`GPIO.out_w1ts` / `GPIO.out_w1tc`) for nanosecond-precision parallel bus transfers to the FPGA.
* **Native lwIP Processing:** Bypasses standard sockets in favor of native lwIP raw UDP callbacks on Core 0 for zero-copy packet processing.
* **Zero-Order Hold (ZOH) Jitter Buffer:** Intelligently handles network micro-jitter by holding the last sample, and gracefully falls back to absolute silence during longer network dropouts.
* **Maximized Wi-Fi Throughput:** Wi-Fi Power Save is completely disabled, and HT40 bandwidth is enabled to drop latency down to 1-3ms.
* **Live Dynamic Control:** Update NCO frequencies and channel gains on the fly without interrupting the audio stream.

---

## 🏗️ System Architecture

```text
+-------------------+                           +---------------+                           +---------------+
|     PC / Server   |       Wi-Fi (UDP)         |     ESP32     |    8-Bit Parallel Bus     |     FPGA      |
|                   |                           |               |    (Data 0-7 + Enable)    |               |
|  FFmpeg (Audio)   | ---(Ports 1234-1243)--->  |  Core 0: lwIP | ------------------------> |  Parses Bus   |
|                   |                           |  Core 1: BUS  | ------------------------> |  Runs 10 NCOs |
|  netcat (Control) | ---(Ports 5000/8888)--->  |               | ------------------------> |  AM Modulator |
+-------------------+                           +---------------+                           +---------------+
```

---

## 🔌 Hardware Setup (Pinout)

The ESP32 communicates with the FPGA using a custom unidirectional parallel bus. Ensure level shifting if your FPGA IO bank does not support 3.3V logic.

| ESP32 Pin | FPGA Bus Signal | Description |
| :--- | :--- | :--- |
| `GPIO_NUM_18` | **EN** (Enable) | Strobe signal to clock data into the FPGA |
| `GPIO_NUM_13` | **D0** (LSB) | Data Bit 0 |
| `GPIO_NUM_14` | **D1** | Data Bit 1 |
| `GPIO_NUM_27` | **D2** | Data Bit 2 |
| `GPIO_NUM_26` | **D3** | Data Bit 3 |
| `GPIO_NUM_25` | **D4** | Data Bit 4 |
| `GPIO_NUM_33` | **D5** | Data Bit 5 |
| `GPIO_NUM_32` | **D6** | Data Bit 6 |
| `GPIO_NUM_19` | **D7** (MSB) | Data Bit 7 |

---

## 🚀 Software Configuration (ESP-IDF)

Before compiling, adjust the following constants at the top of `main.c`:

```c
#define WIFI_SSID       "YOUR_WIFI_SSID"
#define WIFI_PASS       "YOUR_WIFI_PASSWORD"

// IMPORTANT: Set this to the exact clock speed of your FPGA's NCO module!
#define FPGA_CLOCK_HZ   10000000.0 
```

Build and flash using the standard ESP-IDF toolchain:
```bash
idf.py build flash monitor
```

---

## 📡 Network API & Usage

Once the ESP32 is connected to your Wi-Fi, it listens on several UDP ports.

### 1. Streaming Audio (Ports 1234 to 1243)
The ESP32 expects raw 8-bit unsigned PCM audio at 25,000 Hz. You can easily route an internet radio stream directly to the ESP32 using `FFmpeg`.

**Example: Stream an internet radio station to Channel 0 (Port 1234)**
```bash
ffmpeg -re -i "[http://your-radio-stream-url.mp3](http://your-radio-stream-url.mp3)" -ar 25000 -ac 1 -f u8 -acodec pcm_u8 udp://<ESP32_IP>:1234
```
*(Repeat for ports up to 1243 for channels 1 through 9).*

### 2. Setting NCO Frequencies (Port 5000)
To tell the ESP32 which audio port maps to which transmission frequency, send a space-separated string mapping the Port to the Frequency (in Hz). The ESP32 calculates the 32-bit tuning word based on `FPGA_CLOCK_HZ` and sends it to the FPGA.

**Example: Set 603 kHz for Port 1234 and 828 kHz for Port 1235**
```bash
echo -n "1234:603000 1235:828000" | nc -u -w1 <ESP32_IP> 5000
```

### 3. Adjusting Gain / Volume (Port 8888)
You can dynamically adjust the amplitude of any running frequency. Send the frequency in Hz and a linear gain float (between `0.0` and `1.0`). The ESP32 scales this to a 16-bit integer (0-65535) for the FPGA.

**Example: Set 603 kHz to ~25% amplitude and mute 828 kHz**
*(Note: If your FPGA utilizes bit-shifting for attenuation, input the matching decimal values, e.g., 0.25 for -12dB)*
```bash
echo -n "603000:0.25" | nc -u -w1 <ESP32_IP> 8888
echo -n "828000:0.0" | nc -u -w1 <ESP32_IP> 8888
```

---

## 🛠️ FPGA Protocol Specification

If you are writing the Verilog/VHDL code for the FPGA, here is the byte sequence the ESP32 will send over the parallel bus. Every byte is clocked by a rising/falling edge on the `EN` pin.

* **Audio Frame (Sent strictly every 40µs):**
  `'A'` `->` `'U'` `->` `'D'` `->` `[CH0_Byte]` `->` `[CH1_Byte]` `...` `->` `[CH9_Byte]`

* **Frequency Update Frame:**
  `'F'` `->` `'R'` `->` `'Q'` `->` `[40 Bytes total: 10 Channels x 32-bit Tuning Words (MSB first)]`

* **Gain Update Frame:**
  `'G'` `->` `'A'` `->` `'N'` `->` `[Channel_ID (0-9)]` `->` `[Gain_HighByte]` `->` `[Gain_LowByte]`

---
*Created with C, FreeRTOS, and a passion for radio frequencies.*
````</ESP32_IP></ESP32_IP></ESP32_IP></ESP32_IP>
