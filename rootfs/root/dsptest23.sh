#!/bin/sh
# DSP audio experiment 23: half size and volume. Experiment 22 (skip) gave a faint tone,
# beeping, gone when the program stopped: the stream plays our data. The DSP asks every
# 5 ms (200/s) while a 2016-byte half holds 11.4 ms, so each request may take less than a
# half (beeping); audio register 0x3C holds Symbian's idle 0x2000000 (bit 25 = mute, as
# pulsed in 0x24), 0x1C1C during Symbian's headphone playback (faint).
#   sh dsptest23.sh HALF [idle|boot]   (no 3 (1)/(2), 0x3C = 0x1C1C, 8 s)
#
# DSP audio experiment 22: experiment 21 started the stream (semaphore 2 at 200/s) but it
# stayed silent, while Symbian's own stream played (experiment 19). During 3 (1) Symbian's
# power manager changes the DSP PLL (0x60 -> 1e), DSP clock (0x64 -> ff933) and audio PLL
# (0x6C -> 403e04) and restores them before 3 (2); we kept the clocks running. Variants:
#   skip     no 3 (1) / 3 (2)
#   clocks   Symbian's clock changes around them
# (second argument idle|boot as in experiment 21.) Notes of experiment 21 follow.
#
# DSP audio experiment 21: Symbian's WAV stream start, from regprobe's dsptrace of a WAV
# ringtone (2026-10-17 22:10, rom_dump/run_new). The DSP's area-0 stream descriptor at
# shared + 0x440 (0001 .. 0007) appears right after the last message of:
#   70 (0,1); audio 0x24 = 0x2000000; 6 FEV; 3 (1) [low power]; 280 ms; 3 (2) [run];
#   31 (7,81C) + PMASK bff8; 8 (1); 49 (178,0); 70 (0,101); 0x24 = 0x80000, 0; 6 FEV
# 46 is not part of it, 49 is (left out in experiment 20). FEV = Symbian's live headphone
# playback vector 0000 0100 00CF 8034 0000 0000; parameter blocks from the same snapshot.
#   sh dsptest21.sh idle   on the DSP Symbian left (handover with nothing playing)
#   sh dsptest21.sh boot   on our own freshly booted DSP (adds 1, 12, 46, the tables)
# Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
A=0x400E8000
B=busybox
WAV=/media/card/music/tone44k_stereo.wav
FEV="0x0000 0x0100 0x00CF 0x8034 0x0000 0x0000"
m() { $T msg "$@" | grep -v ^stale; }
fev() { $T fev $SH $FEV | grep ^msg; }
a24() { $B devmem $((A + 0x24)) 32 $1; }
clk() { $B devmem $((A + 0x64)) 32 $(( $($B devmem $((A + 0x64))) $1 )); }
desc() { $T save $SH /tmp/s.bin >/dev/null; echo "  0x440: $(od -An -tx2 -j 0x440 -N 16 /tmp/s.bin)"; }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null
V=skip
HALF=${1:-2016}
shift
case "${1:-idle}" in
boot)
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared_live.bin 0x818 0x3E8 >/dev/null
	$T modules $SH 0x81100000 0x8114E000 | grep ^msg
	m 1 0 0
	m 16 0x78 0x85c; m 17 0x78 0x99c; m 52 0x10 0xba4; m 7 8 0; m 63 0x1e5a 0x140f
	m 60 0 0; m 46 0x1000 7; m 14 0 0
	;;
idle)
	$T restore $SH dspshared_live.bin 0x818 0x3E8 >/dev/null
	;;
*)
	echo "usage: $0 HALF [idle|boot]"; exit 1 ;;
esac
$T regs | head -1
desc
echo "-- WAV start sequence"
m 70 0 1
a24 0x2000000
fev
if [ "$V" = clocks ]; then
	m 3 1 0
	$B devmem $((A + 0x60)) 32 0x1e
	$B devmem $((A + 0x64)) 32 0xff933
	$B devmem $((A + 0x6C)) 32 0x403e04
	sleep 0.3
	$B devmem $((A + 0x6C)) 32 0x603e05
	$B devmem $((A + 0x60)) 32 0x1001f
	sleep 0.01
	$B devmem $((A + 0x64)) 32 0xff93f
	clk "& ~0x100"
	m 3 2 0
	clk "| 0x100"
fi
m 31 7 0x81c
m 8 1 0
m 49 0x178 0
m 70 0 0x101
a24 0x80000
a24 0
fev
$B devmem $((A + 0x3C)) 32 0x1C1C
desc
echo ">>> WAV, $HALF-byte halves, semaphore 2"
$T play $SH 0 $HALF 2 2 $WAV 8000
desc
