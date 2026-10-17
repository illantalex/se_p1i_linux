#!/bin/sh
# DSP audio experiment 2: FEV for ARM_PCM1 (accepted with status 0 in experiment 1), then
# message 38 = set up PCM channel 0 (p0 = channel | flag << 4, p1 = its shared area offset,
# area 0 = 0x1000), then try a 1 kHz tone through area 0 (semaphore bit 2 both ways).
# The fill rate printed by "tone" tells how fast the DSP consumes, i.e. the sample format.
F=/lib/firmware/p1i-dsp
SH=0x81100000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"

gpioset -z -c gpiochip6 14=1 15=1 16=1

dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH
dsptool fev $SH $FEV
echo "== msg 38, channel 0, flag 1"
dsptool msg 38 0x10 0x1000
dsptool sem 2000
echo "== tone through area 0, 5 s"
dsptool tone $SH 0 1792 2 2 5000
echo "== msg 38, channel 0, flag 0"
dsptool msg 38 0x00 0x1000
dsptool sem 2000
dsptool regs
