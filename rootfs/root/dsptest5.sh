#!/bin/sh
# DSP audio experiment 5, a listening test (headphones): does the DSP play shared area 0 on
# its own, without semaphores? Area 0 is filled in turns with a 1 kHz sine, silence and a
# 2 kHz sine, 6 s each. If what you hear follows that pattern, the data reaches the DAC.
F=/lib/firmware/p1i-dsp
SH=0x81100000
FEV="0x0000 0x0100 0x00CE 0xCF94 0x33CC 0x0000"
B=/usr/local/bin/busybox

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null
dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep "msg 11"
$B devmem 0x400E8078 32 0
$B devmem 0x400E807C 32 0x010F0100
dsptool fev $SH $FEV | grep ^msg
sleep 2

for step in 1 0 2 0 1; do
	case $step in 0) what="silence" ;; 1) what="1 kHz" ;; 2) what="2 kHz" ;; esac
	echo ">>> $(date +%T) area 0 = $what (6 s)"
	dsptool fill $SH 0 3584 $step
	sleep 6
done
echo ">>> $(date +%T) done"
dsptool regs
