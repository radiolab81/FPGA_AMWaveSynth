#!/bin/bash
echo "--- MULTI-SENDER START ---"

# ************ SDR Settings ******************
SDR_IP="192.168.1.141"
SDR_CONTROL_PORT="5000"
# ************ SDR Settings ******************

# Prüfung auf erforderliche Programme
MISSING=()
for cmd in ffmpeg nc bc; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "FEHLER: Die folgenden Programme sind nicht installiert: ${MISSING[*]}"
    echo "Bitte installiere sie zuerst und starte das Script neu."
    exit 1
fi

MOD_ARGS=""
NC_CMD="" # Variable für den Netcat-String

# Wir verarbeiten die Argumente in 4er-Blöcken (Freq, BW, URL, Port)
while (( "$#" >= 4 )); do
    FREQ=$1
    BW=$(echo "$2 * 1000" | bc | cut -d'.' -f1)
    URL=$3
    PORT=$4
    
    echo "Starte ffmpeg Instanz: $FREQ kHz | BW: $BW kHz | Port: $PORT"
   
    # ffmpeg -i "$URL" -af "lowpass=f=${BW}000" -f mpegts udp://127.0.0.1:$PORT &
    ffmpeg -stream_loop -1 -re -i "$URL" -af "lowpass=f=${BW}, volume=0.8, acompressor=threshold=-10dB:ratio=4"   -f u8 -ar 25000 -ac 1 udp://$SDR_IP:$PORT &  

    # Daten für Netcat im Format "port:frequenz_in_hz" anhängen
    freq_hz=$(echo "$FREQ * 1000" | bc | cut -d'.' -f1)

    if [ -z "$NC_CMD" ]; then
        NC_CMD="${PORT}:${freq_hz}"
    else
        NC_CMD="${NC_CMD} ${PORT}:${freq_hz}"
    fi
  
    
    shift 4 # Die nächsten 4 Parameter nehmen
done


# Sende den gesammelten String an den SDR
if [ -n "$NC_CMD" ]; then
    echo "Sende Frequenzliste an SDR (${SDR_IP}:${SDR_CONTROL_PORT})..."
    echo -n "$NC_CMD" | nc -u -w1 "${SDR_IP}" "${SDR_CONTROL_PORT}"
fi


echo "--------------------------"
echo "Alle Prozesse gestartet. Drücke STRG+C zum Beenden."
# Das Script muss aktiv bleiben, damit xterm offen bleibt
while true; do sleep 5; done
