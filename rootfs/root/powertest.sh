#!/bin/sh
# powertest.sh -- battery current baseline: runs detached, so the USB cable can be pulled
# (the battery current only shows the drain while nothing charges). Phases of PHASE_S
# seconds each: idle with backlight, idle with backlight off, backlight off + CPU busy.
# Samples /run/p1i-battery (p1ibat refreshes it every 60 s), the timer interrupt count and
# p1ibat's CPU time into /root/powertest.log.
#
#   ./powertest.sh [DELAY_S] [PHASE_S]     (defaults 60 and 300)

DELAY=${1:-60}
PHASE=${2:-300}
LOG=/root/powertest.log
BL=/sys/class/backlight/backlight/brightness

if [ "$POWERTEST_BG" != 1 ]; then
	POWERTEST_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached; unplug USB within $DELAY s, log: $LOG"
	exit 0
fi

bat() { grep "^$1=" /run/p1i-battery | cut -d= -f2; }
timer() { awk '/mstim/ { print $2 }' /proc/interrupts; }
p1icpu() { p=$(pidof p1ibat); [ -n "$p" ] && awk '{ print $14 + $15 }' /proc/$p/stat; }

sample() {
	echo "$(date +%T) $1 cur=$(bat battery_current) mv=$(bat battery_mv)" \
	     "state43=$(bat battery_43) pct=$(bat battery_percent) timer=$(timer)" \
	     "p1ibat_ticks=$(p1icpu) load=$(cut -d' ' -f1 /proc/loadavg)" >> $LOG
}

phase() {
	end=$(( $(date +%s) + PHASE ))
	while [ $(date +%s) -lt $end ]; do
		sample "$1"
		sleep 20
	done
}

old=$(cat $BL)
echo "start $(date) delay=$DELAY phase=$PHASE brightness=$old" > $LOG
sleep "$DELAY"
phase idle_bl$old
echo 0 > $BL
phase idle_bl0
yes > /dev/null &
y=$!
phase busy_bl0
kill $y
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
