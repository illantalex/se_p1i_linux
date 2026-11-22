#!/bin/sh
# dspresume.sh -- EXPERIMENT: wake the audio DSP from Symbian's standby the way Symbian does,
# instead of booting it again (dspcold.sh, silent so far), and start a stream on it.
# For a handover with D:\other\nostream.txt: Symbian left the DSP in standby (message 3 (1),
# PLLs off, DSPCLKCTRL bit 7 set), its firmware and everything Symbian set up still inside.
#
# Order and values from regprobe's dsptrace of Symbian starting music after standby
# (2026-11-22): message 3 (2) while the DSP clock is still off (written straight into the
# CMD registers, Symbian does not wait for the reply either); 2 ms later the DSP PLL on and
# DSPCLKCTRL bit 7 cleared with bits 2 and 3 set; message 31 and PMASK; audio PLL on; the
# stream (Symbian: message 32 for its MP3 decoder); message 52's block and message 52;
# message 8 (1, 0); message 49 (0x178, 0); message 70 (0, 0x101); the FEV; DAC (GPO_14) and
# speaker amplifier (GPO_15) on.
#
# Run 1 (2026-11-22, PCM, with 46/49/7/8 before 52 and audio 0x24 written by hand): every
# message answered except, afterwards, 49 (no reply, as in October with the DSP's AHB
# master shut down); no stream requests; status block 0x440 = Symbian's idle values.
# This version leaves audio 0x24 alone and logs it with the status block after each step:
# in Symbian's trace 0x24 changes with messages 70 and 6, most likely written by the DSP
# itself through its AHB master, so a change there shows the AHB master is back.
# Run 2: same; 0x24 unchanged. The firmware never clears the PMU's AHB master and DMA
# shutdown bits after standby (no interrupt recovers them either): a resume cannot work
# from Linux. Superseded by a restart in reset (dsprestart.sh, the ALSA driver).
#
#   ./dspresume.sh [pcm|mp3]   log: /root/dspresume.log
#   pcm (default): 44.1 kHz stereo PCM in area 0, then e.g. a dsptool tone or aplay
#   mp3: Symbian's MP3 decoder setup 1:1 (message 32, FEV source 0x0001), then plays the
#        start of an MP3 through dsptool
cd "$(dirname "$0")"
MODE=${1:-pcm}
LOG=/root/dspresume.log
if [ "$DSPRESUME_LOGGING" != 1 ]; then
	DSPRESUME_LOGGING=1 "$0" "$@" 2>&1 | tee $LOG
	exit
fi
T=./dsptool
SH=0x08000000
A=0x400E8000
P=0x400C0000
B=busybox
MP3="/media/card/music/Disease - Beautiful insanity.mp3"
m() { echo "msg $*: $($T msg "$@" | grep -v "^stale" | tr '\n' ' ')"; }
au() { $B devmem $((A + $1)) 32 $2; }
sh32() { $B devmem $((SH + $1)) 32 $2; }
st() {	# STEP: status block, audio 0x24 and the clocks after STEP
	printf "  [%s] 0x440:" "$1"
	for o in 0 4 8 12; do printf " %s" $(sh32 $((0x440 + o))); done
	echo " a24 $(au 0x24) PLL $($B devmem 0x400E8060) CLK $($B devmem 0x400E8064) PSTS $($B devmem $((P + 0xc)) 16)"
}

if [ $(( $($B devmem 0x400E8060) & 1 )) = 1 ]; then
	echo "DSP PLL already on: not in Symbian's standby" >&2
	exit 1
fi
echo "dspresume $MODE $(date)"
st handover
echo "PADR $($B devmem $((P + 0x4)) 16) (last DSP memory address Symbian wrote through the host port)"
$T regs

echo "== resume"
$B devmem $((P + 0x30)) 16 0	# message 3 (2): CMD2, CMD1, CMD0
$B devmem $((P + 0x28)) 16 2
$B devmem $((P + 0x20)) 16 3
sleep 0.002
$B devmem 0x400E8060 32 0x0001001e
$B devmem 0x400E8064 32 $(printf 0x%x $(( ($($B devmem 0x400E8064) & ~0x80) | 0xc )))
sleep 0.04
$T rep | sed 's/^/  3 (2) /'
st clocks
m 31 7 0x81c
$B devmem $((P + 0x14)) 16 0xbff8
au 0x6c 0x00603e04
sleep 0.004
st audiopll

echo "== stream ($MODE)"
if [ "$MODE" = mp3 ]; then
	m 32 0x2d0 0x1000
	SRC=0x0001
else
	m 46 0x1000 7
	m 7 8 0
	SRC=0x0100
fi
sh32 0xba4 0x00002000
i=0xba8; while [ $((i)) -lt $((0xbc0)) ]; do sh32 $i 0; i=$((i + 4)); done
sh32 0xbc0 0x40340000
m 52 0x10 0xba4
m 8 1 0
m 49 0x178 0
st stream

echo "== output"
m 70 0 0x0101
st msg70
$T fev $SH 0x0000 $SRC 0x00ce 0x8034 0x0000 0x0000 | grep ^msg
st fev
sh32 0x820 0x27dc
m 31 7 0x81c
$B devmem 0x40028004 32 0xc000	# GPO_14 DAC_ON, GPO_15 speaker amplifier
sleep 0.1
st gpo
$T regs

echo "== play"
if [ "$MODE" = mp3 ]; then
	timeout 15 $T play $SH 0 720 2 2 "$MP3" 10000
else
	$T tone $SH 0 1008 2 2 6000 1 0xbff8
fi
st end
