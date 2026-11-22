#!/bin/sh
# dspcold.sh -- EXPERIMENT: start the audio DSP from Linux after Symbian powered it down
# (DSPPLLCTRL bit 0 clear), and set up a PCM stream on it for ALSA, without any state left
# by Symbian. Each step prints its result.
#
#   1. PLLs on, as dspextension exports #29 (audio PLL) and #20/#21 (DSP PLL) do
#   2. boot: Symbian's startup images through the host port (exports #16, #11/#8, #15),
#      with the DSP PMU's module shutdown bits cleared (Symbian's standby, message 3 (1),
#      shut the AHB master down, and a reset keeps that), then message 11 (shared buffer
#      at 0x08000000); the shared buffer is cleared
#   3. message 12: where the codec module and the resampling tables are (the ALSA driver
#      reloads them into the reserved area at probe)
#   4. slot 1 at 44.1 kHz stereo (46, 49), slot 1 = PCM (7), slot 1 on the music path (8)
#   5. message 52's block and message 52
#   6. output 2 = type 1 (message 70) and the FEV, which start the output tasks
#   7. the route (audio-route.sh headphones|speaker, default headphones), DSP semaphore 2
#      unmasked for the ALSA driver
#
#   ./dspcold.sh [headphones|speaker]
#
# Status (2026-10-24): every message was accepted and the DSP took PCM at the right pace,
# but the output stayed silent: its output tasks did not start (the status block at shared
# + 0x440 stayed empty). Step 6 was missing then (found 2026-11-15, not tested yet).
# Message 16's block (0x85c) and 17's (0x99c) are not written here.
# Never send message 3 (1) afterwards: standby shuts the AHB master down again.
cd "$(dirname "$0")"
T=./dsptool
SH=0x08000000
B=busybox
F=/lib/firmware/p1i-dsp
m() { echo "msg $*: $($T msg "$@" | grep -v "^stale" | tr '\n' ' ')"; }

echo "== PLLs"
# DSPCLKCTRL bit 7: set by Symbian when it powers the DSP down; the host port (APBP) then
# answers every access with a bus error
$B devmem 0x400E8064 32 $(printf 0x%x $(($($B devmem 0x400E8064 32) & ~0x80)))
$B devmem 0x400E806C 32 0x00603e04
sleep 0.05
$B devmem 0x400E8064 32 $(printf 0x%x $(($($B devmem 0x400E8064 32) | 0x4)))
$B devmem 0x400E8060 32 0x0001001e
sleep 0.05
$B devmem 0x400E8064 32 $(printf 0x%x $(($($B devmem 0x400E8064 32) | 0x8)))
echo "AUDIOPLL $($B devmem 0x400E806C 32) DSPPLL $($B devmem 0x400E8060 32) DSPCLK $($B devmem 0x400E8064 32)"

echo "== boot"
$T boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | tail -4

echo "== modules"
$T modules $SH 0x81050000 0x8109E000 | grep -v "^stale"

echo "== PCM stream"
m 46 0x1000 7
m 49 0x178 0
m 7 8 0
m 8 1 0
$B devmem 0x08000ba4 16 0x2000
i=$((0x08000ba6))
while [ $i -lt $((0x08000bc2)) ]; do $B devmem $i 16 0; i=$((i + 2)); done
$B devmem 0x08000bc2 16 0x4034
m 52 0x10 0xba4

# The output tasks start only with both (DSP firmware 0x2163/0x22a9): an output type from
# message 70 (p1 high byte = output 2's type; Symbian plays music with p0 0, p1 0x0101) and
# FEV halfword 2 bit 7 (0x0080) going from clear to set. Symbian's live FEV while playing.
echo "== outputs"
m 70 0 0x0101
$T fev $SH 0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000 | grep ^msg

echo "== route"
./audio-route.sh "${1:-headphones}"
$B devmem 0x400C0014 16 0xbff8
$T regs
