
This version utilizes Time-Division Multiplexing to further scale the channels and reduce the consumption of hardware multipliers and LUTs.

Comparison of a 10-channel version on a very old and small EP2C5:


| Resource / Parameter | Fully Parallel NCO Processing | Semi-Parallel / TDM NCO Cores | Resource Savings |
| :--- | :---: | :---: | :---: |
| **Total logic elements** | 4,463 / 4,608 (97 %) | 910 / 4,608 (20 %) | **-77%** |
| **Total combinational functions** | 4,440 / 4,608 (96 %) | 759 / 4,608 (16 %) | **-80%** |
| **Dedicated logic registers** | 1,980 / 4,608 (43 %) | 523 / 4,608 (11 %) | **-32%** |
| **Total registers** | 1,980 | 523 | **-1,457 Reg.** |
| **Embedded Multiplier 9-bit** | 26 / 26 (100 %) | 10 / 26 (38 %) | **-62%** |
| **Total memory bits** | 81,920 / 119,808 (68 %) | 17,494 / 119,808 (15 %) | **-53%** |
| **Total pins** | 20 / 89 (22 %) | 20 / 89 (22 %) | 0% (Unchanged) |
| **Total virtual pins** | 0 | 0 | Unchanged |
| **Total PLLs** | 0 / 2 (0 %) | 0 / 2 (0 %) | Unchanged |

By utilizing TDM techniques and RAM blocks, a remarkably large number of radio stations can be achieved even on very old and small FPGAs.
As a rule, the pertinent issue here is no longer the number of available NCOs, but rather the fact that the user must provide an adequate modulation source for every generated radio station.
