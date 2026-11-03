#!/bin/sh
# powertest3.sh -- EXPERIMENT: what do the CPU/bus clocks cost? Runs detached (pull the USB
# cable first), backlight off throughout. Phases: base; DIRECT RUN (ARM, HCLK and SDRAM at
# SYSCLK = 13 MHz instead of 208/104 MHz; PERIPH_CLK stays 13 MHz, so UARTs keep their
# rates); direct run with the HCLK PLL powered down; then back to normal and base again.
# Same steps as Symbian's idle code (PowerControlExtension.dll): SDRAM refresh 6 (x16
# cycles = 7.4 us at 13 MHz) before leaving the PLL, PWR_CTRL bit 2 = normal RUN mode,
# HCLKPLL_CTRL bit 16 = PLL power, bit 0 = lock; the refresh value is restored after.
# Everything is very slow meanwhile. Do NOT plug USB in before the screen lights up again.
# Log: /root/powertest3.log
#
#   ./powertest3.sh [DELAY_S] [PHASE_S]     (defaults 90 and 180)

DELAY=${1:-90}
PHASE=${2:-180}
LOG=/root/powertest3.log
BL=/sys/class/backlight/backlight/brightness
B=busybox
PWR_CTRL=0x40004044
HCLKPLL=0x40004058
EMC_REFRESH=0x31080024

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
	     "state43=$(bat battery_43) pwr=$(r $PWR_CTRL) pll=$(r $HCLKPLL)" \
	     "refresh=$(r $EMC_REFRESH) overruns=$(bat overruns)" >> $LOG
}
phase() {
	end=$(( $(date +%s) + PHASE ))
	while [ $(date +%s) -lt $end ]; do
		sample "$1"
		sleep 20
	done
}

old=$(cat $BL)
pwr=$(r $PWR_CTRL)
pll=$(r $HCLKPLL)
refresh=$(r $EMC_REFRESH)
echo "start $(date) delay=$DELAY phase=$PHASE pwr=$pwr pll=$pll refresh=$refresh" > $LOG
[ $((pwr & 4)) = 4 ] && [ $((pll & 0x10001)) = $((0x10001)) ] ||
	{ echo "not in normal RUN mode with a locked PLL, not touching it" >> $LOG; exit 1; }
sleep "$DELAY"
echo 0 > $BL
phase base

w $EMC_REFRESH 6
w $PWR_CTRL $(( pwr & ~4 ))
phase direct_run

w $HCLKPLL $(( pll & ~0x10000 ))
phase direct_pll_off

w $HCLKPLL $pll
i=0
while [ $(( $(r $HCLKPLL) & 1 )) = 0 ] && [ $i -lt 100 ]; do i=$((i + 1)); done
if [ $(( $(r $HCLKPLL) & 1 )) = 1 ]; then
	w $PWR_CTRL $pwr
	w $EMC_REFRESH $refresh
	echo "$(date +%T) back to RUN mode, PLL locked after $i polls" >> $LOG
else
	echo "$(date +%T) PLL DID NOT LOCK, staying in direct run (reboot)" >> $LOG
fi
phase base2
echo "$old" > $BL
sample end
echo "done $(date)" >> $LOG
