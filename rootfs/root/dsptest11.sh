#!/bin/sh
# DSP audio experiment 11: experiment 10 (msg 32 starts area 0: the DSP asks for data once
# or twice, then stalls) with the audio interface block set as during Symbian's WAV
# playback. After the handover it holds Symbian's idle values: 0x24 0008FCFC, 0x28 21,
# 0x3C FCFC, 0x40 690 (playing: 0, 220, 1C1C, 7D0) -- muted/powered-down output, which
# would block the DSP's output and with it the stream. Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
A=0x400E8000
FEV="0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000"
B=busybox

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
$T restore $SH dspshared3.bin 0x400 0xC00 >/dev/null
$T modules $SH 0x81100000 0x8114E000 | grep ^msg
for t in 0x860 0x9a0; do $T msg 31 7 $t | grep ^msg; done
$T fev $SH $FEV | grep ^msg

echo "== audio interface as during Symbian playback"
$B devmem $((A + 0x24)) 32 0x00000000
$B devmem $((A + 0x28)) 32 0x00000220
$B devmem $((A + 0x3C)) 32 0x00001C1C
$B devmem $((A + 0x40)) 32 0x000007D0
for o in 0x24 0x28 0x3C 0x40; do printf '%s: ' $o; $B devmem $((A + o)); done

$T msg 32 0x2d0 0x1000
echo ">>> 1 kHz tone, 8 s"
$T tone $SH 0 2016 2 2 8000 1 0xbff8
$T rep
for o in 0x24 0x28 0x3C 0x40; do printf '%s: ' $o; $B devmem $((A + o)); done
