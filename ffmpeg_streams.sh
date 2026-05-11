ffmpeg -re -i /media/user/HDD2/Radiochannels/Linda_Abba_Ch/01-Rebelle.m4a \
    -af "lowpass=f=4500,pan=10c|c0=c0|c1=c1|c2=c0|c3=c1|c4=c0|c5=c1|c6=c0|c7=c1|c8=c0|c9=c1,aresample=12500" \
    -f u8 -acodec pcm_u8 udp://127.0.0.1:4444