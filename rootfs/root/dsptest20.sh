#!/bin/sh
# DSP audio experiment 20: Symbian's idle DSP + our stream start. Hand over with Symbian idle
# (nothing playing), then run this once (headphones on). The DSP is NOT rebooted: it keeps
# Symbian's boot-time setup (modules loaded at 0x8105xxxx/0x8109xxxx, parameters), which our
# own boot seems to lack -- with it, area 0's stream descriptor at 0x440 never appears.
# A handover during playback continues fine (experiment 19); an idle one has no stream.
# Sequence from regprobe's dsptrace of a ringtone start, 46 (area 0 PCM, format 7) in place
# of the MP3 framing message 32. Parameter blocks 0x810-0xBFF from Symbian's playback
# snapshot (0x800, the module block, is left as Symbian set it).
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
A=0x400E8000
B=busybox
WAV=/media/card/music/tone44k_stereo.wav
m() { $T msg "$@" | grep -v ^stale; }
a24() { $B devmem $((A + 0x24)) 32 $1; }
clk() { $B devmem $((A + 0x64)) 32 $(( $($B devmem $((A + 0x64))) $1 )); }
desc() { $T save $SH /tmp/s.bin >/dev/null; echo "  0x440: $(od -An -tx2 -j 0x440 -N 16 /tmp/s.bin)"; }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null
$T regs | head -1
desc
$T restore $SH dspshared_run2.bin 0x810 0x3F0 >/dev/null
a24 0x2000000
m 70 0 1
m 6 6 0x810
m 3 1 0
sleep 2
clk "& ~0x100"
m 3 2 0
clk "| 0x100"
m 31 7 0x81c
m 46 0x1000 7
m 8 1 0
a24 0x80000
m 70 0 0x101
m 6 6 0x810
a24 0
m 14 1 0
desc
$T sem 500 | tail -1
desc
echo ">>> WAV, 2016-byte halves, semaphore 2"
timeout 25 $T play $SH 0 2016 2 2 $WAV
$T regs | head -1
