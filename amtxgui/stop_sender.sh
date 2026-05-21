#!/bin/bash
# Schließt den Prozessbaum, der vom xterm (PID $1) gestartet wurde
#pkill -P $1

# ************ SDR Settings ******************
SDR_IP="192.168.1.141"
SDR_CONTROL_PORT="5000"
# ************ SDR Settings ******************

killall ffmpeg

# Alle NCOs um FPGA "killen"
echo -n "1234:000000 1235:000000 1236:000000 1237:000000 1238:000000 1239:000000 1240:000000 1241:000000 1242:000000 1243:000000 1244:000000" | nc -u -w1 $SDR_IP $SDR_CONTROL_PORT