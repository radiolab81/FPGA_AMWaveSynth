echo -n "1234:522000 1235:540000 1236:594000 1237:639000 1238:756000 1239:792000 1240:927000 1241:1053000 1242:1215000 1243:1440000 1244:1539000" | nc -u -w1 192.168.1.141 5000



ffmpeg -re -stream_loop -1 -i http://alpes1gap.ice.infomaniak.ch/alpes1gap-high.mp3 \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1234?pkt_size=1024" &



ffmpeg -re -stream_loop -1 -i http://direct.francebleu.fr/live/fbalsace-midfi.mp3 \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1235?pkt_size=1024" &


ffmpeg -re -stream_loop -1 -i http://direct.franceculture.fr/live/franceculture-lofi.mp3 \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1236?pkt_size=1024" &


ffmpeg -re -stream_loop -1 -i http://broadcast.infomaniak.ch/frequencejazz-high.mp3 \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1237?pkt_size=1024" &


ffmpeg -re -stream_loop -1 -i http://k6fm.ice.infomaniak.ch/k6fm-64.aac \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1238?pkt_size=1024" &


ffmpeg -re -stream_loop -1 -i https://47fm.ice.infomaniak.ch/47fm-agen.mp3 \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1239?pkt_size=1024" &


ffmpeg -re -stream_loop -1 -i https://47fm.ice.infomaniak.ch/47fm-80.aac \
    -af "lowpass=f=4500,acompressor=threshold=-10dB:ratio=4,volume=0.8,aresample=25000:async=1" \
    -ac 1 \
    -c:a pcm_u8 \
    -f u8 \
    "udp://192.168.1.141:1240?pkt_size=1024"

