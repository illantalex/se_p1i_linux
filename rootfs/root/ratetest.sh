#!/bin/sh
# ratetest.sh [RATE...] -- play the same music at different sample rates through the DSP,
# which resamples itself (no resampling on the ARM). Default: all rates in /root/rates.
#
# As Symbian does it (rom_dump/run_48k, run_22k): message 46 (area 0x1000, rate index)
# and message 49 (SRC filter table 0x108 + 16 * index). Rate index: 0 8000, 1 11025,
# 2 12000, 3 16000, 4 22050, 5 24000, 6 32000, 7 44100, 8 48000. The DSP keeps taking
# 1008-byte halves (252 frames) at any rate. Afterwards it is set back to 44.1 kHz.
#
# Files: /root/rates/song_RATE.raw (raw 16-bit stereo). Output: headphones.
# Stop ALSA playback first (the driver and dsptool would both fill the halves).
cd "$(dirname "$0")"
T=./dsptool

index() {
	case $1 in
	8000) echo 0 ;; 11025) echo 1 ;; 12000) echo 2 ;; 16000) echo 3 ;; 22050) echo 4 ;;
	24000) echo 5 ;; 32000) echo 6 ;; 44100) echo 7 ;; 48000) echo 8 ;; *) echo -1 ;;
	esac
}

setrate() {
	$T msg 46 0x1000 $1 | grep -v "^stale" | grep -v "status 0$"
	$T msg 49 $(printf "0x%x" $((0x108 + 16 * $1))) 0 | grep -v "^stale" | grep -v "status 0$"
}

./audio-route.sh headphones
rates=${*:-"44100 48000 32000 22050 16000 11025 8000"}
for r in $rates; do
	i=$(index $r)
	f=rates/song_$r.raw
	if [ "$i" -lt 0 ] || [ ! -f "$f" ]; then
		echo "skipping $r (unknown rate or no $f)"
		continue
	fi
	echo ">>> $r Hz (index $i)"
	setrate $i
	$T play 0x08000000 0 1008 2 2 "$f" 13000 | tail -1
	sleep 1
done
setrate 7
echo "back to 44100 Hz"
