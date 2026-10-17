#!/bin/sh
# DSP audio experiment 12: message 38 after message 32. dspcontrolldd request 10 sends
# message 38 with p0 = channel | flag << 4, p1 = area offset (channel 0 -> 0x1000). Before
# message 32 existed in our sequence, the flag form always answered status 3. With 32
# (area 0 started; the DSP asks for data twice, then stalls) try:
#   A = 32, 38 flag      B = 38 no flag, 32, 38 flag      C = 32, 34, 38 flag
# Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
FEV="0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000"

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

setup() {
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared3.bin 0x400 0xC00 >/dev/null
	$T modules $SH 0x81100000 0x8114E000 | grep ^msg
	for t in 0x860 0x9a0; do $T msg 31 7 $t | grep ^msg; done
	$T fev $SH $FEV | grep ^msg
}

for v in A B C; do
	echo; echo "=== variant $v"
	setup
	case $v in
	A) $T msg 32 0x2d0 0x1000; $T msg 38 0x10 0x1000 ;;
	B) $T msg 38 0x00 0x1000; $T msg 32 0x2d0 0x1000; $T msg 38 0x10 0x1000 ;;
	C) $T msg 32 0x2d0 0x1000; $T msg 34 0x310 0x1000; $T msg 38 0x10 0x1000 ;;
	esac 2>&1 | grep -v ^stale
	echo ">>> $v: 1 kHz tone, 5 s"
	$T tone $SH 0 2016 2 2 5000 1 0xbff8
	$T rep
	sleep 2
done
