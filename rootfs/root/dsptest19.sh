#!/bin/sh
# DSP audio experiment 19: continue Symbian's own stream. Start tone44k_stereo.wav in
# Symbian's music player, hand over while it plays, then run this (headphones on). The DSP
# is NOT rebooted: it still runs Symbian's playback and asks for area 0 data (semaphore 2
# was pending after earlier handovers during playback). dsptool play serves the requests
# like ExtSoundPdd: the WAV (44.1 kHz 16-bit stereo) in 2016-byte halves, then the tone.
#   plays on: our handshake and the output work, the gap is in our DSP setup
#   stalls after two halves: our side of the handshake (PSEM) is wrong
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
WAV=/media/card/music/tone44k_stereo.wav

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null
echo "== state left by Symbian"
$T regs
for a in 0x24 0x3C 0x58 0x5C; do printf '  audio %s: ' $a; busybox devmem $((0x400E8000 + a)); done
echo ">>> WAV, 2016-byte halves, semaphore 2"
timeout 25 $T play $SH 0 2016 2 2 $WAV
$T regs
