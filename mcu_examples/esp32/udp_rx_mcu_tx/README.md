# 📻 ESP32 UDP-to-FPGA AM Radio Bridge

This project implements a hard real-time, ultra-low latency bridge between IP networks (Internet Radio) and an FPGA. It turns your ESP32 and FPGA into a multi-channel AM radio transmitter / modulator. 

The ESP32 receives up to 10 independent audio streams via Wi-Fi (UDP), handles jitter buffering, and pushes the multiplexed audio alongside dynamic frequency and gain configuration to an FPGA via a high-speed 8-bit parallel bus. The FPGA can then use Numerically Controlled Oscillators (NCOs) to generate a genuine Medium Wave (AM) radio frequency spectrum.

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
|                   |                           |  Core 1: I2S  | ------------------------> |  Runs 10 NCOs |
|  netcat (Control) | ---(Ports 5000/8888)--->  |               | ------------------------> |  AM Modulator |
+-------------------+                           +---------------+                           +---------------+