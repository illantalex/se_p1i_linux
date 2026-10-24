#!/bin/sh
# dspwake.sh -- EXPERIMENT: wake the audio DSP after Symbian put it into standby and switched
# its PLLs off (DSPPLLCTRL bit 0 clear), in the order Symbian does it (regprobe dsptrace
# 2026-10-24, rom_dump/dsp_new: music started 1 min after the last sound):
#   message 3 (2) = resume, written while the DSP is still unclocked (3 (1) = standby is
#   what Symbian sent before switching the PLLs off), with DSPCLKCTRL bit 7 cleared and
#   bit 8 cleared during the send (dspcontrolldd 0xf83741f0); DSPCLKCTRL bits 2-3 and the
#   DSP PLL together; the audio PLL ~35 ms later; then the reply to message 3.
# Then message 52 checks that the DSP reads the shared buffer again (status 0).
# "dspwake.sh down" does Symbian's power-down instead: message 3 (1), PLLs off.
#
# Does not work: the DSP answers messages again, but its AHB master stays shut down in its
# PMU (standby's doing, no interrupt recovers it), so message 52 gets status 3. dspcold.sh
# boots the DSP again with those PMU bits cleared instead.
cd "$(dirname "$0")"
T=./dsptool
B=busybox

if [ "$1" = down ]; then
	$T msg 3 1 0 | grep -v "^stale"
	$B devmem 0x400E8064 32 $(printf 0x%x $((($($B devmem 0x400E8064 32) | 0x80) & ~0xc)))
	$B devmem 0x400E8060 32 0x0000001e
	$B devmem 0x400E806C 32 0x00403e04
	echo "down: DSPPLL $($B devmem 0x400E8060 32) DSPCLK $($B devmem 0x400E8064 32) AUDIOPLL $($B devmem 0x400E806C 32)"
	exit 0
fi

echo "before: DSPPLL $($B devmem 0x400E8060 32) DSPCLK $($B devmem 0x400E8064 32) AUDIOPLL $($B devmem 0x400E806C 32)"
# message 3 (2) with DSPCLKCTRL bits 7 and 8 clear; it waits up to 2 s for the reply,
# which comes once the DSP runs
CLK=$(($($B devmem 0x400E8064 32) & ~0x80))
$B devmem 0x400E8064 32 $(printf 0x%x $((CLK & ~0x100)))
$T msg 3 2 0 > /tmp/dspwake.msg3 2>&1 &
sleep 0.01
$B devmem 0x400E8064 32 $(printf 0x%x $((CLK | 0x100 | 0xc)))
$B devmem 0x400E8060 32 0x0001001e
sleep 0.035
$B devmem 0x400E806C 32 0x00603e04
wait
grep -v "^stale" /tmp/dspwake.msg3
echo "after: DSPPLL $($B devmem 0x400E8060 32) DSPCLK $($B devmem 0x400E8064 32) AUDIOPLL $($B devmem 0x400E806C 32)"

# message 52's block (the shared buffer may have been cleared), then the check
$B devmem 0x08000ba4 16 0x2000
i=$((0x08000ba6))
while [ $i -lt $((0x08000bc2)) ]; do $B devmem $i 16 0; i=$((i + 2)); done
$B devmem 0x08000bc2 16 0x4034
$T msg 52 0x10 0xba4 | grep -v "^stale"
