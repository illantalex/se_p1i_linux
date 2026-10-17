#!/bin/sh
# Snapshot of the DSP's state into DIR (default /root/snap-<time>): registers and the shared
# buffer. (DSP memory cannot be read through the host port the way the 3DS allows: on the
# PNX4008 that wedges the port -- every access aborts until DSPCLKCTRL bits 0x1020 are
# toggled, which also resets the DSP.)
cd "$(dirname "$0")"
T=./dsptool
D=${1:-/root/snap-$(date +%H%M%S)}
mkdir -p $D
$T regs > $D/regs.txt
$T save 0x08000000 $D/shared.bin
echo "saved to $D"
