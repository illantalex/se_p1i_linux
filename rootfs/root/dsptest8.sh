#!/bin/sh
# DSP audio experiment 8: give the DSP its codec module and SRC filter coefficients. Symbian
# loads DspCodecModule.bin and DspSrcFilterCoefs.bin into SDRAM (0x81050000 / 0x8109E000) and
# announces them with message 12 (block at shared+0x800: 1, 1, addr1, addr2). Here they go
# into the kernel's no-map reservation at 0x81100000 (384 KB), same 0x4E000 apart.
# Then Symbian's live FEV and the tone through area 0 (2016-byte halves, sem bit 2).
# Run A sends message 12 before the FEV, run B after it. Headphones on.
F=/lib/firmware/p1i-dsp
SH=0x08000000
M1=0x81100000
M2=0x8114E000
FEV="0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000"

for f in DspStartupCode.bin DspStartupData.bin DspCodecModule.bin DspSrcFilterCoefs.bin; do
	[ -f $F/$f ] || { echo "missing $F/$f"; exit 1; }
done
gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

for run in A B; do
	echo "=== run $run"
	dsptool load $F/DspCodecModule.bin $M1 || exit 1
	dsptool load $F/DspSrcFilterCoefs.bin $M2 || exit 1
	dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
	if [ $run = A ]; then
		dsptool modules $SH $M1 $M2
		dsptool sem 1000 | tail -3
		dsptool fev $SH $FEV | grep ^msg
	else
		dsptool fev $SH $FEV | grep ^msg
		dsptool modules $SH $M1 $M2
	fi
	echo "== semaphores (2 s)"
	dsptool sem 2000 | tail -4
	echo "== tone through area 0, 2016-byte halves, 6 s"
	dsptool tone $SH 0 2016 2 2 6000
	dsptool regs
done
