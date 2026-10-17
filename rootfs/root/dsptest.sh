#!/bin/sh
# DSP audio experiment: boot the DSP, send the use case (FEV) for ARM_PCM1 playback on the
# music stream to both speaker paths, and watch which DSP->ARM semaphores it raises: that
# tells which shared area the DSP plays from (see dsptool.c for the area/bit tables).
F=/lib/firmware/p1i-dsp
SH=0x81100000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"

# Audio amplifiers on: GPO_14 DAC_ON, GPO_15 SPK_SHDN# (speaker), GPO_16 SHF_SHDN# (headphones)
gpioset -z -c gpiochip6 14=1 15=1 16=1

dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH
echo "== semaphores before the FEV (1 s)"
dsptool sem 1000
echo "== FEV, halfwords in suzifev.h order"
dsptool fev $SH $FEV
dsptool sem 3000
echo "== FEV, pairs swapped (high halfword first)"
dsptool fev $SH $FEV swap
dsptool sem 3000
dsptool regs
