#!/bin/sh
# DSP audio experiment 6: the shared buffer in the PNX4008's internal SRAM (0x08000000), as
# Symbian has it (regprobe: shared buffer linear 66420000 physical 08000000), not in SDRAM.
# Boot, FEV for ARM_PCM1, then a 1 kHz tone through area 0 (semaphore bit 2 both ways).
# Headphones on.
F=/lib/firmware/p1i-dsp
SH=0x08000000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11|notification"
dsptool fev $SH $FEV | grep ^msg
echo "== semaphores after the FEV (2 s)"
dsptool sem 2000 | tail -4
echo "== tone through area 0, 6 s"
dsptool tone $SH 0 1792 2 2 6000
echo "== msg 38 channel 0 (flag 0 / 1)"
dsptool msg 38 0x00 0x1000 | grep ^msg
dsptool msg 38 0x10 0x1000 | grep ^msg
dsptool sem 1000 | tail -2
dsptool tone $SH 0 1792 2 2 4000
dsptool regs
