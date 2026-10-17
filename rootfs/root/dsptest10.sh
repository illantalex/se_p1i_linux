#!/bin/sh
# DSP audio experiment 10: the area-0 stream messages. M3SAudioDevMgr.dll (mmmgmtserver)
# drives dspcontrolldd; for area 0 its stream function issues request 8 -> message 32
# (p0 0x2D0, p1 0x1000 = area 0) and request 9 -> message 34 (p0 0x310, p1 0x1000),
# both without arguments from user space. Never sent so far. Each variant reboots the DSP,
# loads the modules (msg 12), restores Symbian's parameter areas, sends the gains (msg 31)
# and the live FEV, then: A = msg 32, B = msg 32 + 34, C = msg 34. Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
M1=0x81100000
M2=0x8114E000
FEV="0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000"

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

setup() {
	$T load $F/DspCodecModule.bin $M1 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin $M2 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared3.bin 0x400 0xC00 >/dev/null
	$T modules $SH $M1 $M2 | grep ^msg
	for t in 0x860 0x9a0; do $T msg 31 7 $t | grep ^msg; done
	$T fev $SH $FEV | grep ^msg
}

for v in A B C; do
	echo; echo "=== variant $v"
	setup
	case $v in
	A) $T msg 32 0x2d0 0x1000 ;;
	B) $T msg 32 0x2d0 0x1000; $T msg 34 0x310 0x1000 ;;
	C) $T msg 34 0x310 0x1000 ;;
	esac
	echo "== semaphores (1 s)"
	$T sem 1000 | tail -3
	echo ">>> $v: 1 kHz tone, 5 s"
	$T tone $SH 0 2016 2 2 5000 1 0xbff8
	$T rep
	sleep 2
done
