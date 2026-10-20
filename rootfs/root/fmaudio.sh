#!/bin/sh
# fmaudio.sh [SHARED_SNAPSHOT] -- EXPERIMENT: route the FM receiver's audio (codec input
# AUDIO_IN1) through the DSP to the headphones on a normal boot (DSP stream adopted from
# Symbian for music), by recreating the state Symbian's FM radio leaves behind.
#
# Reference: a handover with the FM radio playing and Linux not touching the DSP plays the
# radio fine (2026-10-20, rom_dump/fm_linux). Compared with music playback, that state has:
#   clock block: 0x40004030 and 0x40004038 bit 13 set (0x40004034/44 as for music)
#   audio block 0x400E8000: input section +0x48..+0x5C and +0x7C, headphones on (+0x3C)
#   shared buffer 0x800-0xBFF: FEV (0x810), gains, filters and, at 0xADC-0xB4A, FM's table
#     where music has its transfer table -- restored here from the snapshot (default
#     /root/fm_shared.bin, the DSP shared buffer saved in that state, not in git)
#   last messages: 3 (2, 0), 7 (0x400, 0), 8 (2, 0), 18 (0x38, 0xadc), 80 (8, 1),
#     46 (0x1000, 0x100), FEV (6); headphone routing (70, 16) as audio-route.sh
# The message order is a guess; each reply is printed. Stop ALSA playback first and run
# fm.sh on MHz before, with the headphones in. A reboot undoes it all.
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
A=0x400E8000
B=busybox
SNAP=${1:-/root/fm_shared.bin}
m() { echo "msg $*: $($T msg "$@" | grep -v "^stale" | tr '\n' ' ')"; }
au() { $B devmem $((A + $1)) 32 $2; }
setbit() { $B devmem $1 32 $(printf "0x%08x" $(($($B devmem $1 32) | $2))); echo "$1 = $($B devmem $1 32)"; }

[ -f "$SNAP" ] || { echo "no snapshot $SNAP"; exit 1; }

echo "== clocks"
setbit 0x40004030 0x2000
setbit 0x40004038 0x2000

echo "== headphone route"
./audio-route.sh headphones

echo "== audio input section"
au 0x48 0x00000003
au 0x4c 0x00000001
au 0x50 0x00000080
au 0x54 0x001c0a0a
au 0x58 0x00001000
au 0x5c 0x00000000
au 0x7c 0x010f0100

echo "== shared buffer 0x800-0xbff from $SNAP"
$T restore $SH "$SNAP" 0x800 0x400

echo "== messages"
m 3 2 0
m 7 0x400 0
m 8 2 0
m 16 0x78 0x85c
m 18 0x38 0xadc
m 70 0x0201 0x0101
m 80 8 1
m 46 0x1000 0x100
m 6 0x0006 0x0810
echo "done: any sound? (fm.sh info shows the signal)"
