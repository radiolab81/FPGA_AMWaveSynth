This version utilizes Time-Division Multiplexing to further scale the channels and reduce the consumption of hardware multipliers and LUTs.

Comparison of a 10-channel version on a very old and small EP2C5:

### fully parallel nco processing

Revision Name	am_modulator_top
Top-level Entity Name	am_modulator_top
Family	Cyclone II
Device	EP2C5T144C8
Timing Models	Final
Total logic elements	4,463 / 4,608 ( 97 % )
Total combinational functions	4,440 / 4,608 ( 96 % )
Dedicated logic registers	1,980 / 4,608 ( 43 % )
Total registers	1980
Total pins	20 / 89 ( 22 % )
Total virtual pins	0
Total memory bits	81,920 / 119,808 ( 68 % )
Embedded Multiplier 9-bit elements	26 / 26 ( 100 % )
Total PLLs	0 / 2 ( 0 % )


### semi-prallel / TDM nco cores

Revision Name	am_modulator_top
Top-level Entity Name	am_modulator_top
Family	Cyclone II
Device	EP2C5T144C8
Timing Models	Final
Total logic elements	910 / 4,608 ( 20 % )
Total combinational functions	759 / 4,608 ( 16 % )
Dedicated logic registers	523 / 4,608 ( 11 % )
Total registers	523
Total pins	20 / 89 ( 22 % )
Total virtual pins	0
Total memory bits	17,494 / 119,808 ( 15 % )
Embedded Multiplier 9-bit elements	10 / 26 ( 38 % )
Total PLLs	0 / 2 ( 0 % )


By utilizing TDM techniques and RAM blocks, a remarkably large number of radio stations can be achieved even on very old and small PFPGAs.
As a rule, the pertinent issue here is no longer the number of available NCOs, but rather the fact that the user must provide an adequate modulation source for every generated radio station.