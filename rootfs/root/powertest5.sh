#!/bin/sh
# powertest5.sh -- EXPERIMENT: do peripherals left powered cost battery? Runs detached (pull
# the USB cable first if it charges), backlight off, STOP mode idle on throughout. Alternates
# phases with GPO pins OFF (cleared) and back as found, ROUNDS times:
#   GPO_03 = ADC_FM_POW (FM receiver and codec input supply, hogged high by the DT),
#   GPO_08 = BT_RST# (Bluetooth out of reset).
# P3_OUTP_SET 0x40028004 / P3_OUTP_CLR 0x40028008, GPO_n = bit n. The modem's battery
# current is a slow average, so the phases are long. Log: /root/powertest5.log
#
#   ./powertest5.sh [DELAY_S] [PHASE_S] [ROUNDS] [BITS]   (defaults 60, 900, 2, 0x108)

DELAY=${1:-60}
PHASE=${2:-900}
ROUNDS=${3:-2}
BITS=${4:-0x108}
LOG=/root/powertest5.log
BL=/sys/class/backlight/backlight/brightness
P=/sys/module/pnx4008_idle/parameters
B=busybox
OUTP_SET=0x40028004
OUTP_CLR=0x40028008
OUTP_STATE=0x4002800C

if [ "$POWERTEST_BG" != 1 ]; then
	POWERTEST_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached; unplug USB within $DELAY s if it charges, log: $LOG"
	exit 0
fi

bat() { grep "^$1=" /run/p1i-battery | cut -d= -f2; }
sample() {
	echo "$(date +%T) $1 cur=$(bat battery_current) mv=$(bat battery_mv)" \
	     "state43=$(bat battery_43) pct=$(bat battery_percent)" \
	     "gpo=$($B devmem $OUTP_STATE) stops=$(cat $P/stops)" >> $LOG
}
phase() {
	end=$(( $(date +%s) + PHASE ))
	while [ $(date +%s) -lt $end ]; do
		sample "$1"
		sleep 30
	done
}

old=$(cat $BL)
oldstop=$(cat $P/stop)
was=$(( $($B devmem $OUTP_STATE) & BITS ))
echo "start $(date) delay=$DELAY phase=$PHASE rounds=$ROUNDS bits=$BITS (were $was)" > $LOG
sleep "$DELAY"
echo 0 > $BL
echo 1 > $P/stop
i=0
while [ $i -lt "$ROUNDS" ]; do
	$B devmem $OUTP_CLR 32 $BITS
	phase gpo_off
	[ "$was" != 0 ] && $B devmem $OUTP_SET 32 $(printf 0x%x $was)
	phase gpo_on
	i=$((i + 1))
done
[ "$oldstop" = Y ] || echo 0 > $P/stop
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
