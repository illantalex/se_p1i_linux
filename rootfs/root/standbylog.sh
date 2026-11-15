#!/bin/sh
# standbylog.sh -- standby battery test: STOP mode idle on, backlight off, the phone left
# alone for HOURS; every INTERVAL seconds the battery state goes to a log on the card
# (synced, so it survives a freeze or an empty battery). Runs detached: pull the USB
# cable, or the modem tops the battery up from USB. At the end the backlight and the idle
# mode are restored. Log: /media/card/other/standby.log
#
#   ./standbylog.sh [HOURS] [INTERVAL_S]     (defaults 10 and 300)

HOURS=${1:-10}
INTERVAL=${2:-300}
LOG=/media/card/other/standby.log
BL=/sys/class/backlight/backlight/brightness
P=/sys/module/pnx4008_idle/parameters

if [ "$STANDBY_BG" != 1 ]; then
	STANDBY_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached for $HOURS h; pull the USB cable now; log: $LOG"
	exit 0
fi

bat() { grep "^$1=" /run/p1i-battery | cut -d= -f2; }
sample() {
	echo "$(date +%F_%T) $1 pct=$(bat battery_percent) level=$(bat level)" \
	     "mv=$(bat battery_mv) cur=$(bat battery_current) state43=$(bat battery_43)" \
	     "temp=$(bat battery_29) stops=$(cat $P/stops) uptime=$(cut -d' ' -f1 /proc/uptime)" \
	     >> $LOG
	sync
}

old=$(cat $BL)
oldstop=$(cat $P/stop)
echo "start $(date) hours=$HOURS interval=$INTERVAL" >> $LOG
sleep 60
echo 0 > $BL
echo 1 > $P/stop
end=$(( $(date +%s) + HOURS * 3600 ))
while [ $(date +%s) -lt $end ]; do
	sample standby
	sleep "$INTERVAL"
done
[ "$oldstop" = Y ] || echo 0 > $P/stop
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
sync
