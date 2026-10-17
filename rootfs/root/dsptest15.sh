#!/bin/sh
# DSP audio experiment 15: message order. Experiment 13/14 replayed Symbian's message set
# with message 46 (area 0 PCM stream) last: the DSP then ticks semaphore 14 at 200 Hz (and 1
# once) -- dspcontrolldd's notification semaphores (it binds 0, 1 and 14; each completes a
# user request) -- but never raises area 0's PCM semaphore 2, which Symbian has pending
# during playback. The dump gives the messages, not their order. Here 46 comes before the
# state-like messages (3 = 2, 60, 14 x2): A = after 70, B = right after the FEV,
# C = as before plus a second 3 (2) after 46. The tone waits for bit 2, other bits are
# acknowledged. Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
m() { $T msg "$@" | grep -v ^stale | grep -v "status 0$"; }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

boot() {
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared_run2.bin 0x400 0xC00 >/dev/null
	$T modules $SH 0x81100000 0x8114E000 | grep -v ^stale | grep -v "status 0$"
	m 1 0 0
	m 6 6 0x810
}
params() {
	m 31 7 0x81c; m 31 7 0x84c; m 16 0x78 0x85c; m 17 0x78 0x99c; m 52 0x10 0xba4
	m 49 0x178 0; m 7 8 0; m 8 1 0; m 63 0x1e5a 0x140f; m 70 0x0201 0x0101
}
state() { m 3 2 0; m 60 0 0; m 14 0 0; m 14 1 0; }

for v in A B C; do
	echo; echo "=== variant $v (only messages with a non-zero status are shown)"
	boot
	case $v in
	A) params; m 46 0x1000 7; state ;;
	B) m 46 0x1000 7; params; state ;;
	C) params; state; m 46 0x1000 7; m 3 2 0 ;;
	esac
	echo ">>> $v: 1 kHz tone, waiting for semaphore 2, 6 s"
	$T tone $SH 0 2016 2 2 6000 1 0xbff8
	$T rep
	sleep 2
done
