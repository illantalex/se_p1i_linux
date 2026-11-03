#!/bin/sh
# powertest2.sh -- EXPERIMENT: does the USB clock cost battery while unplugged? Runs
# detached (pull the cable first), backlight off throughout. Phases: base, then the USB PLL
# off and the main 13 MHz oscillator stopped (as Symbian keeps it; the system runs from
# PLL397), then both restored, then base again. Nothing may touch the USB block while its
# clock is off: do NOT plug the cable back in before the screen lights up again.
# Log: /root/powertest2.log
#
#   ./powertest2.sh [DELAY_S] [PHASE_S]     (defaults 90 and 180)

DELAY=${1:-90}
PHASE=${2:-180}
LOG=/root/powertest2.log
BL=/sys/class/backlight/backlight/brightness
B=busybox
USB_CTRL=0x40004064
OSC_CTRL=0x4000404C

if [ "$POWERTEST_BG" != 1 ]; then
	POWERTEST_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached; unplug USB within $DELAY s, log: $LOG"
	exit 0
fi

r() { $B devmem $1 32; }
w() { $B devmem $1 32 $(printf 0x%x $2); }
bat() { grep "^$1=" /run/p1i-battery | cut -d= -f2; }
sample() {
	echo "$(date +%T) $1 cur=$(bat battery_current) mv=$(bat battery_mv)" \
	     "state43=$(bat battery_43) usb=$(r $USB_CTRL) osc=$(r $OSC_CTRL)" >> $LOG
}
phase() {
	end=$(( $(date +%s) + PHASE ))
	while [ $(date +%s) -lt $end ]; do
		sample "$1"
		sleep 20
	done
}

old=$(cat $BL)
usb=$(r $USB_CTRL)
osc=$(r $OSC_CTRL)
echo "start $(date) delay=$DELAY phase=$PHASE usb=$usb osc=$osc" > $LOG
sleep "$DELAY"
echo 0 > $BL
phase base

# off: block clock enable (bit 18), PLL power/clock requests (0x00470000), then the oscillator
w $USB_CTRL $(( usb & ~0x00470000 ))
sleep 0.05
w $OSC_CTRL $(( osc | 1 ))
phase usb_off

# on again, as clk-pnx4008-usb does: oscillator, PLL, wait for lock, then the clock enable
w $OSC_CTRL $(( osc & ~1 ))
sleep 0.1
w $USB_CTRL $(( usb & ~0x00040000 ))
i=0
while [ $(( $(r $USB_CTRL) & 1 )) = 0 ] && [ $i -lt 50 ]; do sleep 0.02; i=$((i + 1)); done
if [ $(( $(r $USB_CTRL) & 1 )) = 1 ]; then
	w $USB_CTRL $usb
	echo "$(date +%T) restored, PLL locked after $i polls" >> $LOG
else
	echo "$(date +%T) PLL DID NOT LOCK, USB left off (reboot before plugging in)" >> $LOG
fi
phase base2
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
