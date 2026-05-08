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
- 12-13 channels on rock-old EP2C5 without techniques such as time multiplexing are no problem, 16-24 AM stations using time-multiplexing without special tricks, with further optimizations, of course, even more

- Contemporary FPGAs in the hobby sector such as Tang Nano 25k, 50-60 AM stations without effort, using time-multiplexing 200+ AM stations, more than a complete long- and medium-wave band together!

Good prerequisites for realizing the AMWaveSynth as an FPGA chip, in addition to the existing software version.
