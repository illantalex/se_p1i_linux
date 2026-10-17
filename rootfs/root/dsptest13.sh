#!/bin/sh
# DSP audio experiment 13: Symbian's own message set for WAV playback, read from
# dspcontrolldd's channel object during playback (regprobe 7a555a9, dspchan1.bin): every
# request keeps its last message. Not used: 32/34 (codec framing) and 38. Used, with these
# parameters (order unknown, guessed below):
#   1; 12 (6,800); 6 FEV (6,810); 31 gains (7,81C) (7,84C); 16 (78,85C); 17 (78,99C);
#   52 (10,BA4); 49 (178,0); 7 (8,0); 8 (1,0); 63 (1E5A,140F); 70 (0201,0101); 3 (2,0);
#   60; 14 (0) and 14 (1); 46 (1000, 7) = area 0 PCM stream, format 7.
# The parameter blocks are in the shared buffer snapshot of the same run
# (dspshared_run2.bin, restored 0x400-0xFFF). Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
m() { $T msg "$@" | grep -v ^stale; }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

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
echo "== semaphores (1 s)"
$T sem 1000 | tail -3
echo ">>> 1 kHz tone, 8 s"
$T tone $SH 0 2016 2 2 8000 1 0xbff8
$T rep
