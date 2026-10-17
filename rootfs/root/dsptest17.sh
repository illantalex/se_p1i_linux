#!/bin/sh
# DSP audio experiment 17: Symbian's stream start, from regprobe's dsptrace while an MP3
# ringtone started (2026-10-17, rom_dump/regprobe.log):
#   A24 = 0x2000000; 70 (0000,0001); 6 FEV; 3 (1) [DSP PLL, DSP clock and audio PLL change];
#   2.3 s later 3 (2) [clocks back]; 31 (7,81C); PMASK bff8; 32 (02D0,1000) for MP3;
#   8 (1); A24 = 0x80000; 70 (0000,0101); 6 FEV; A24 = 0.
# Message 3 is a power state (1 = low power, 2 = run): we only ever sent 3 (2), to a DSP
# never in state 1. dspcontrolldd clears DSPCLKCTRL bit 0x100 before 3 (2) and sets it
# after. Setup: boot, modules, 1, the parameter messages and 46 (area 0 PCM, format 7)
# as in Symbian's channel dump; then the start sequence with A = 46 again in place of 32,
# B = 32 as in the trace (MP3 framing). The tone waits for semaphore 2. Headphones on.
cd "$(dirname "$0")"
T=./dsptool
F=/lib/firmware/p1i-dsp
SH=0x08000000
A=0x400E8000
B=busybox
m() { $T msg "$@" | grep -v ^stale | grep -v "status 0$"; }
a24() { $B devmem $((A + 0x24)) 32 $1; }
clk() { $B devmem $((A + 0x64)) 32 $(( $($B devmem $((A + 0x64))) $1 )); }
regs() { printf '  DSPPLL %s DSPCLK %s AUDIOPLL %s\n' $($B devmem $((A + 0x60))) \
	$($B devmem $((A + 0x64))) $($B devmem $((A + 0x6C))); }

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

for v in A B; do
	echo; echo "=== variant $v (only messages with a non-zero status are shown)"
	$T load $F/DspCodecModule.bin 0x81100000 >/dev/null || exit 1
	$T load $F/DspSrcFilterCoefs.bin 0x8114E000 >/dev/null || exit 1
	$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	$T restore $SH dspshared_run2.bin 0x800 0x400 >/dev/null
	$T modules $SH 0x81100000 0x8114E000 | grep -v ^stale | grep -v "status 0$"
	m 1 0 0
	m 6 6 0x810
	m 16 0x78 0x85c; m 17 0x78 0x99c; m 52 0x10 0xba4; m 49 0x178 0; m 7 8 0
	m 63 0x1e5a 0x140f; m 60 0 0; m 46 0x1000 7
	regs
	echo "-- start sequence"
	a24 0x2000000
	m 70 0 1
	m 6 6 0x810
	m 3 1 0
	regs
	sleep 2
	clk "& ~0x100"
	m 3 2 0
	clk "| 0x100"
	regs
	m 31 7 0x81c
	if [ $v = A ]; then m 46 0x1000 7; else m 32 0x2d0 0x1000; fi
	m 8 1 0
	a24 0x80000
	m 70 0 0x101
	m 6 6 0x810
	a24 0
	m 14 1 0
	echo ">>> $v: 1 kHz tone, waiting for semaphore 2, 6 s"
	$T tone $SH 0 2016 2 2 6000 1 0xbff8
	$T rep
	sleep 2
done
