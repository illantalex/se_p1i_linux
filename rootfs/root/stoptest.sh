#!/bin/sh
# stoptest.sh -- EXPERIMENT: switch the STOP mode idle on for a few seconds (detached, as USB
# may drop meanwhile) and log pnx4008_idle's counters every second to the card, synced, so
# that a freeze leaves the last state behind. Log: /media/card/other/stoptest.log
#
#   ./stoptest.sh [SECONDS]      (default 10)

SECS=${1:-10}
LOG=/media/card/other/stoptest.log
P=/sys/module/pnx4008_idle/parameters

if [ "$STOPTEST_BG" != 1 ]; then
	STOPTEST_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "running detached for $SECS s, log: $LOG"
	exit 0
fi

counters() {
	echo "$(cut -d' ' -f1 /proc/uptime) $1 entries=$(cat $P/entries) stops=$(cat $P/stops)" \
	     "pending=$(cat $P/stop_pending) pll_slow=$(cat $P/pll_slow)" \
	     "wake_timer=$(cat $P/wake_timer) wake_int=$(printf %x $(cat $P/wake_int))" \
	     "wake_pin=$(printf %x $(cat $P/wake_pin))" >> $LOG
	sync
}

echo "start $(date)" > $LOG
counters before
echo 1 > $P/stop
i=0
while [ $i -lt "$SECS" ]; do
	t0=$(cut -d' ' -f1 /proc/uptime)
	sleep 0.5
	t1=$(cut -d' ' -f1 /proc/uptime)
	echo "sleep 0.5 took $t0 -> $t1" >> $LOG
	counters stop_on
	i=$((i + 1))
done
echo 0 > $P/stop
counters after
echo "done $(date)" >> $LOG
sync
