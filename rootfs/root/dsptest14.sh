#!/bin/sh
# DSP audio experiment 14: experiment 13 (Symbian's message set, message 46 starts area 0)
# made the DSP raise semaphores 1 and 14 about 200 times a second (Symbian's playback mask
# bff8 unmasks 0-2 and 14), but the tone loop waited for bit 2. Now: A = wait for bit 14,
# B = wait for bit 1; any other bit is acknowledged; the ARM->DSP bit stays 2.
# Uses ./dsptool (new build) and ./dspshared_run2.bin. Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
m() { $T msg "$@" | grep -v ^stale | grep -v "status 0$"; }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

setup() {
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared_run2.bin 0x400 0xC00
	# 0x800 (modules) and 0x810 (FEV) as in the snapshot, but with our module addresses
	$T modules $SH 0x81100000 0x8114E000 | grep ^msg
	m 1 0 0
	m 6 6 0x810
	m 31 7 0x81c
	m 31 7 0x84c
	m 16 0x78 0x85c
	m 17 0x78 0x99c
	m 52 0x10 0xba4
	m 49 0x178 0
	m 7 8 0
	m 8 1 0
	m 63 0x1e5a 0x140f
	m 70 0x0201 0x0101
	m 3 2 0
	m 60 0 0
	m 14 0 0
	m 14 1 0
	m 46 0x1000 7
}

for v in A B; do
	echo; echo "=== variant $v (only messages with a non-zero status are shown)"
	setup
	[ $v = A ] && in=14 || in=1
	echo ">>> $v: 1 kHz tone, waiting for semaphore $in, 8 s"
	$T tone $SH 0 2016 $in 2 8000 1 0xbff8
	$T rep
	sleep 2
done
