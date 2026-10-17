#!/bin/sh
# DSP audio experiment 4: the audio interface clock. With Symbian's FM radio playing,
# AUDIOCONFIG+0x7C (0x400E807C) = 0x010F0100 (dspextension #19(1)); idle it is 0, so the DSP
# has no sample clock. Set it, then FEV and the area-0 tone (with headphones plugged in).
F=/lib/firmware/p1i-dsp
SH=0x81100000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"
B=/usr/local/bin/busybox

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

boot() { dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"; }
m() { dsptool msg "$@" | grep -E "^msg"; }
clk() { $B devmem 0x400E8078 32 0; $B devmem 0x400E807C 32 0x010F0100
	echo "AUDIOCONFIG 70-7C: $($B devmem 0x400E8070) $($B devmem 0x400E8074) $($B devmem 0x400E8078) $($B devmem 0x400E807C)"; }

echo "=== 1: clock, FEV, semaphores, tone through area 0"
boot; clk; dsptool fev $SH $FEV | grep ^msg
dsptool sem 1000 | tail -3
dsptool tone $SH 0 1792 2 2 4000

echo "=== 2: clock, FEV, msg 70 (0101), msg 38 channel 0 start, tone"
boot; clk; dsptool fev $SH $FEV | grep ^msg
m 70 0x0101 0x0001; m 38 0x10 0x1000
dsptool sem 1000 | tail -3
dsptool tone $SH 0 1792 2 2 4000

echo "=== 3: FEV first, clock after"
boot; dsptool fev $SH $FEV | grep ^msg; clk
dsptool sem 1000 | tail -3
dsptool tone $SH 0 1792 2 2 4000
dsptool regs
