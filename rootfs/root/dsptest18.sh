#!/bin/sh
# DSP audio experiment 18: real MP3 data for the DSP's decoder. With message 32 (area 0
# codec framing, as in Symbian's MP3 ringtone trace) the DSP asks for two halves and stops
# -- what a decoder does when the data has no MP3 frames (we sent a sine). Here the MP3 from
# the card is streamed with dsptool play: A = 1440-byte halves (message 32's p0 0x2D0 in
# 16-bit words), B = 720, C = 2016. Music in the headphones = the DSP output path works.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
A=0x400E8000
B=busybox
MP3="/media/card/music/Disease - Beautiful insanity.mp3"
m() { $T msg "$@" | grep -v ^stale | grep -v "status 0$"; }
a24() { $B devmem $((A + 0x24)) 32 $1; }
clk() { $B devmem $((A + 0x64)) 32 $(( $($B devmem $((A + 0x64))) $1 )); }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

for v in A B C; do
	case $v in A) half=1440 ;; B) half=720 ;; C) half=2016 ;; esac
	echo; echo "=== variant $v: $half-byte halves (only messages with a non-zero status are shown)"
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared_run2.bin 0x800 0x400 >/dev/null
	$T modules $SH 0x81100000 0x8114E000 | grep -v ^stale | grep -v "status 0$"
	m 1 0 0
	m 6 6 0x810
	m 16 0x78 0x85c; m 17 0x78 0x99c; m 52 0x10 0xba4; m 49 0x178 0; m 7 8 0
	m 63 0x1e5a 0x140f; m 60 0 0
	a24 0x2000000
	m 70 0 1
	m 6 6 0x810
	m 3 1 0
	sleep 1
	clk "& ~0x100"
	m 3 2 0
	clk "| 0x100"
	m 31 7 0x81c
	m 32 0x2d0 0x1000
	m 8 1 0
	a24 0x80000
	m 70 0 0x101
	m 6 6 0x810
	a24 0
	m 14 1 0
	echo ">>> $v: MP3, up to 20 s"
	timeout 25 $T play $SH 0 $half 2 2 "$MP3"
	$T rep
	sleep 2
done
