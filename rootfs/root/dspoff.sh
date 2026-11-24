#!/bin/sh
# dspoff.sh -- EXPERIMENT: put the audio DSP into standby as Symbian does when nothing has
# played for a while, so pnx4008-idle can use STOP again (it does not while the DSP PLL
# runs): amplifiers and DAC off (GPO_15/16, GPO_14), outputs stopped (message 70 (0, 1),
# FEV all 0), message 3 (1), then the PLLs off (DSPPLLCTRL bit 16, DSPCLKCTRL bits 2 and 3,
# AUDIOPLLCTRL bit 21). For standby measurements: sound needs a new boot afterwards (the
# driver only restarts a powered-down DSP at probe).
cd "$(dirname "$0")"
T=./dsptool
B=busybox
killall gpioset 2>/dev/null
$B devmem 0x40028008 32 0x1c000		# P3_OUTP_CLR: GPO_14, 15, 16
$T msg 70 0 0x0001 | grep ^msg
$T fev 0x08000000 0 0 0 0 0 0 | grep ^msg
$T msg 3 1 0 | grep ^msg
sleep 0.1
$B devmem 0x400E8060 32 $(printf 0x%x $(( $($B devmem 0x400E8060) & ~0x10000 )))
$B devmem 0x400E8064 32 $(printf 0x%x $(( $($B devmem 0x400E8064) & ~0xc )))
$B devmem 0x400E806C 32 $(printf 0x%x $(( $($B devmem 0x400E806C) & ~0x200000 )))
echo "DSPPLL $($B devmem 0x400E8060) DSPCLK $($B devmem 0x400E8064) AUDIOPLL $($B devmem 0x400E806C) GPO $($B devmem 0x4002800C)"
