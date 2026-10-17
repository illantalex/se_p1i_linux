#!/bin/sh
# DSP audio experiment 16: like experiment 15, but only the ARM-written parameter blocks
# (0x800-0xBFF) are restored from Symbian's snapshot. 0x400-0x7FF stays zero: it holds the
# DSP's own stream state (0x440: 0001 .. 0007 and counters moving during playback), which a
# freshly booted DSP should not find. Variants as in experiment 15: message 46 (area 0 PCM
# stream) A = after the parameter messages, B = right after the FEV, C = last plus a second
# 3 (2). The tone waits for area 0's semaphore 2; other bits are acknowledged. Headphones on.
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
	$T restore $SH dspshared_run2.bin 0x800 0x400 >/dev/null
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
