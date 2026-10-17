#!/bin/sh
# DSP audio experiment 9. Experiment 8 (msg 12 + live FEV) gave a faint tone with no DSP
# semaphores at all. Is it real playback of the two prefilled halves, or interference?
#  1/2: same tone at 1 kHz, then 3 kHz (only the data changes), PMASK bff8 as on Symbian
#  3: silence in the buffer, same polling (interference would stay)
#  4: Symbian's parameter areas (0x400-0xFFF of its shared buffer during WAV playback,
#     incl. the 7-halfword gain tables at 0x860/0x9A0) restored, msg 31 with them, 1 kHz
# Uses ./dsptool (new build) and ./dspshared3.bin from the same directory. Headphones on.
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
	[ "$1" = restore ] && $T restore $SH dspshared3.bin 0x400 0xC00
	$T modules $SH $M1 $M2
	$T fev $SH $FEV | grep ^msg
}
say() { echo; echo ">>> $*"; sleep 2; }

setup
say "1: 1 kHz tone, 5 s"
$T tone $SH 0 2016 2 2 5000 1 0xbff8
say "2: 3 kHz tone (only the data differs), 5 s"
$T tone $SH 0 2016 2 2 5000 3 0xbff8
say "3: silence in the buffer, same polling, 5 s"
$T tone $SH 0 2016 2 2 5000 0 0xbff8

setup restore
for t in 0x860 0x9a0; do $T msg 31 7 $t; done
say "4: Symbian's parameter areas + msg 31 gains, 1 kHz, 5 s"
$T tone $SH 0 2016 2 2 5000 1 0xbff8
$T regs
