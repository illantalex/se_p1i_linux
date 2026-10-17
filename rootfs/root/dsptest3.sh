#!/bin/sh
# DSP audio experiment 3: which sequence lets message 38 (PCM channel setup, flag = start?)
# succeed. Each scenario starts with a fresh DSP boot; watch the status of each message and
# whether any DSP->ARM semaphore appears.
F=/lib/firmware/p1i-dsp
SH=0x81100000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"
AREA="0x1000 0x1e00 0x2600 0x0000"	# shared areas 0-3

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

boot() { dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"; }
m() { dsptool msg "$@" | grep -E "^msg"; }

for ch in 0 1 2 3; do
	off=$(echo $AREA | cut -d' ' -f$((ch + 1)))
	echo "=== A$ch: FEV, then msg 38 channel $ch start"
	boot; dsptool fev $SH $FEV | grep ^msg
	m 38 $((0x10 + ch)) $off
	dsptool sem 600 | tail -1
done

echo "=== B: msg 38 channel 0 setup, FEV, msg 38 start"
boot; m 38 0 0x1000; dsptool fev $SH $FEV | grep ^msg; m 38 0x10 0x1000
dsptool sem 600 | tail -1

echo "=== C: msg 38 channel 0 start before the FEV"
boot; m 38 0x10 0x1000; dsptool fev $SH $FEV | grep ^msg
dsptool sem 600 | tail -1

echo "=== D: FEV, msg 70 (variants), msg 38 start"
for p0 in 0x0101 0x0201 0x0500 0x1500 0x2500; do
	boot; dsptool fev $SH $FEV | grep ^msg; m 70 $p0 0x0001; m 38 0x10 0x1000
	dsptool sem 400 | tail -1
done
