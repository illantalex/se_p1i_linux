#!/bin/sh
# fm-listen.sh MHz|seek [headphones|speaker] -- EXPERIMENT: FM radio without Symbian's help.
# The Si4703's audio goes to SUZI's line input (AUDIO_IN1); the DSP captures it and plays it
# like the PCM stream. Tunes with fm.sh, routes with audio-route.sh, then switches the DSP's
# source to line in as the driver's "Audio Source" control does after a FM handover:
# area 0 back to 8 kHz mono (46 0x100) with its SRC table (49), line in captured at 48 kHz
# (80), slot 2 on the music path (8), FEV source halfword = line in (0x0800), the route
# halfwords as audio-route.sh's. The headset cable is the antenna: headphones in, no USB,
# so run it from the phone's console. Stop: ./fm.sh off; aplay or audio-route.sh for PCM.
#
#   ./fm-listen.sh 101.1 [headphones|speaker]   or   ./fm-listen.sh seek [...]
#
# Status (2026-11-23): plays clean on a restarted DSP (headphones and speaker). Needed: slot 2
# = line in (msg 7 0x0408) and audio 0x7c before message 80 (else 80 answers ok and starts
# nothing), and full bus speed: with direct-run idle the stream sounds robotic (si470x holds
# a PM QoS request while open since #153; before, only a connected USB cable did).
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
OUT=${2:-headphones}
m() { $T msg "$@" | grep -v "^stale" | grep -v "status 0$"; }

if [ "$1" = seek ]; then
	./fm.sh on
	./fm.sh seek
else
	./fm.sh on "$1"
fi
./audio-route.sh "$OUT"
# Slot 2 = line in (msg 7: slot 1 PCM, slot 2 line in); without it message 80 answers ok
# and starts nothing. Audio reg 0x7c as Symbian's radio has it: the DSP reads it when it
# sets up the codec input (0x48-0x58), and it probably selects the input.
# Message 18 with the table Symbian's radio keeps at 0xadc (0x70 bytes, the same in every
# FM snapshot; /root/fm_shared.bin is a shared buffer saved while Symbian's radio played)
[ -f /root/fm_shared.bin ] && $T restore $SH /root/fm_shared.bin 0xadc 0x70 >/dev/null &&
	m 18 0x38 0xadc
m 7 0x0408 0
busybox devmem 0x400E807C 32 0x010f0100
m 46 0x1000 0x100
m 49 0x188 0
m 80 8 1
m 8 2 0
if [ "$OUT" = speaker ]; then
	$T fev $SH 0 0x0800 0x00ce 0x8034 0 0 | grep -v "status 0$"
else
	$T fev $SH 0 0x0800 0x0080 0x48b4 0 0 | grep -v "status 0$"
fi
busybox devmem 0x400C0014 16 $(printf 0x%x $(( $(busybox devmem 0x400C0014 16) | 4 )))
echo "FM on $OUT (./fm.sh seek | tune MHz | info; ./fm.sh off to stop)"
