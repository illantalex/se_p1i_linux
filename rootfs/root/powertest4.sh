#!/bin/sh
# powertest4.sh -- does idling in direct run mode (13 MHz, drivers/misc/pnx4008-idle.c) save
# battery? Runs detached (pull the USB cable first if it charges), backlight off throughout.
# Alternates phases with the direct run idle on and off, ROUNDS times. The modem's battery
# current is a slow average (it changes every 5-12 minutes), so the phases are long; the
# voltage and percentage over the whole run count as well.
# Log: /root/powertest4.log
#
#   ./powertest4.sh [DELAY_S] [PHASE_S] [ROUNDS]     (defaults 60, 900 and 2)

DELAY=${1:-60}
PHASE=${2:-900}
ROUNDS=${3:-2}
LOG=/root/powertest4.log
BL=/sys/class/backlight/backlight/brightness
P=/sys/module/pnx4008_idle/parameters

if [ "$POWERTEST_BG" != 1 ]; then
	POWERTEST_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached; unplug USB within $DELAY s if it charges, log: $LOG"
	exit 0
fi

bat() { grep "^$1=" /run/p1i-battery | cut -d= -f2; }
sample() {
	echo "$(date +%T) $1 cur=$(bat battery_current) mv=$(bat battery_mv)" \
	     "state43=$(bat battery_43) pct=$(bat battery_percent) level=$(bat level)" \
	     "entries=$(cat $P/entries) uptime_idle=$(cat /proc/uptime)" >> $LOG
}
phase() {
	echo "$2" > $P/enable
	end=$(( $(date +%s) + PHASE ))
	while [ $(date +%s) -lt $end ]; do
		sample "$1"
		sleep 30
	done
}

old=$(cat $BL)
echo "start $(date) delay=$DELAY phase=$PHASE rounds=$ROUNDS" > $LOG
sleep "$DELAY"
echo 0 > $BL
i=0
while [ $i -lt "$ROUNDS" ]; do
	phase direct_run 1
	phase full_speed 0
	i=$((i + 1))
done
echo 1 > $P/enable
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
