#!/bin/sh
# audio-route.sh headphones|speaker [GAIN]
#
# Switch the running DSP playback stream (adopted from Symbian, see snd-pnx4008-dsp)
# between the speaker and the headphones, the way Symbian does it when the headphones are
# plugged in or out during playback (regprobe dsptrace 2026-10-18, rom_dump/run_18_10):
#
#   amplifier off (GPO_15 speaker / GPO_16 headphones); FEV with the effect chain off;
#   audio reg 0x24 = 0x2000000 (mute); gains 0; the output's filter coefficients
#   (0x85C table) and 0x940; messages 52 and 16; message 70 = output (0x0201 headphones,
#   0x0000 speaker); 0x24 = 0x80000; headphone output 0x3C (0x2020 on, 0x2002020 off);
#   FEV of the output; 0x24 = 0; gain of the output (halfword 0x81C headphones, 0x820
#   speaker; Q15) with message 31; the other amplifier on.
#
# GAIN: Q15 (default 0x312c headphones, 0x27dc speaker, as Symbian; 0x7fff = maximum).
# The amplifier GPIOs stay held by a background gpioset.
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
A=0x400E8000
B=busybox
m() { $T msg "$@" | grep -v "^stale" | grep -v "status 0$"; }
fev() { $T fev $SH "$@" | grep -v "^stale" | grep -v "status 0$"; }
sh32() { $B devmem $((SH + $1)) 32 $2; }
au() { $B devmem $((A + $1)) 32 $2; }
amps() { killall gpioset 2>/dev/null; gpioset -z -c gpiochip6 15=$1 16=$2; }

case "$1" in
headphones|hp)
	G=${2:-0x312c}
	amps 0 0
	fev 0 0x100 0 0 0 0
	au 0x24 0x2000000
	sh32 0x81c 0; sh32 0x820 0; sh32 0x84c 0; sh32 0x850 0
	sh32 0x864 0x01100110; sh32 0x868 0x7ffc7ffc; sh32 0x870 0x0050fffb
	sh32 0x874 0x40270002; sh32 0x940 0x20200000
	m 52 0x10 0xba4
	m 16 0x78 0x85c
	m 70 0x0201 0x0101
	au 0x24 0x80000
	au 0x3c 0x2020
	fev 0 0x100 0x0080 0x48b4 0 0
	au 0x24 0
	sh32 0x81c $G
	m 31 7 0x81c
	amps 0 1
	;;
speaker|spk)
	G=${2:-0x27dc}
	amps 0 0
	fev 0 0x100 0 0 0 0
	au 0x24 0x2000000
	au 0x3c 0x2002020
	sh32 0x81c 0; sh32 0x820 0
	sh32 0x864 0x01430143; sh32 0x868 0x20272027; sh32 0x870 0x0050fff9
	sh32 0x874 0x7fff0002; sh32 0x940 0
	m 52 0x10 0xba4
	m 16 0x78 0x85c
	m 70 0 0x101
	au 0x24 0x80000
	fev 0 0x100 0x00ce 0x8034 0 0
	au 0x24 0
	sh32 0x820 $G
	m 31 7 0x81c
	amps 1 0
	;;
*)
	echo "usage: $0 headphones|speaker [GAIN]" >&2
	exit 1
	;;
esac
