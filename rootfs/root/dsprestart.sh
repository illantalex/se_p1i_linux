#!/bin/sh
# dsprestart.sh -- EXPERIMENT: restart the audio DSP on the firmware and data Symbian left in
# it (dsptool restart: PMU shutdown bits cleared in reset, reset released, message 11), then
# set up a PCM stream as dspcold.sh does. For a DSP that Symbian put into standby: its
# resume (message 3 (2), 2026-11-22) leaves the AHB master shut down, and nothing in the
# firmware clears the PMU bits (only a write through the host port in reset does).
# Unlike dspcold.sh no images are loaded: whatever boot does not initialise keeps Symbian's
# values. Log: /root/dsprestart.log
#
# Status (2026-11-22): plays loud and clean through the speaker (DAC_ON and message 17 were
# the missing pieces). The ALSA driver does this restart itself at probe now (patch 0073).
#
#   ./dsprestart.sh [headphones|speaker]   (default speaker)
cd "$(dirname "$0")"
if [ "$DSPRESTART_LOGGING" != 1 ]; then
	DSPRESTART_LOGGING=1 "$0" "$@" 2>&1 | tee /root/dsprestart.log
	exit
fi
T=./dsptool
SH=0x08000000
A=0x400E8000
B=busybox
m() { echo "msg $*: $($T msg "$@" | grep -v "^stale" | tr '\n' ' ')"; }
st() {
	printf "  [%s] 0x440:" "$1"
	for o in 0 4 8 12; do printf " %s" $($B devmem $((SH + 0x440 + o))); done
	echo " a24 $($B devmem $((A + 0x24)))"
}

echo "dsprestart $(date)"
echo "== clocks"
[ $(( $($B devmem 0x400E8060) & 1 )) = 1 ] || $B devmem 0x400E8060 32 0x0001001e
$B devmem 0x400E8064 32 $(printf 0x%x $(( ($($B devmem 0x400E8064) & ~0x80) | 0xc )))
$B devmem 0x400E806C 32 0x00603e04
sleep 0.05
st before

echo "== restart"
$T restart $SH
st restart

echo "== modules"
$T modules $SH 0x81050000 0x8109E000 | grep -v "^stale"
# the output filter blocks Symbian left in the shared buffer: without message 17 the
# speaker output is barely audible and noisy (2026-11-22)
m 16 0x78 0x85c
m 17 0x78 0x99c

echo "== PCM stream"
m 31 7 0x81c
m 46 0x1000 7
m 7 8 0
m 8 1 0
$B devmem $((SH + 0xba4)) 32 0x00002000
i=0xba8; while [ $((i)) -lt $((0xbc0)) ]; do $B devmem $((SH + i)) 32 0; i=$((i + 4)); done
$B devmem $((SH + 0xbc0)) 32 0x40340000
m 52 0x10 0xba4
m 49 0x178 0
st stream

echo "== outputs"
$B devmem $((A + 0x24)) 32 0x12345	# marker: the DSP rewrites 0x24 when its outputs start
m 70 0 0x0101
st msg70
$T fev $SH 0x0000 0x0100 0x00ce 0x8034 0x0000 0x0000 | grep ^msg
st fev

echo "== route"
./audio-route.sh "${1:-speaker}"
$B devmem 0x40028004 32 0x4000	# GPO_14 DAC_ON: off in Symbian's standby, audio-route.sh only switches the amplifiers
$B devmem 0x400C0014 16 0xbff8
st route
$T regs

echo "== tone"
$T tone $SH 0 1008 2 2 6000 1 0xbff8
st end
