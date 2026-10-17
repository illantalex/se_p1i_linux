#!/bin/sh
# Snapshot of the DSP's state into DIR (default /root/snap-<time>): the shared buffer and
# the DSP's data memory, read through the host port while it runs. Data words
# 0x8000-0x87FF are the DSP's I/O registers and are not read. First 16 program words are
# compared with DspStartupCode.bin to check that host-port reads work.
cd "$(dirname "$0")"
T=./dsptool
D=${1:-/root/snap-$(date +%H%M%S)}
mkdir -p $D
$T regs > $D/regs.txt
$T peek prog 0 16 $D/prog16.bin
if cmp -s -n 32 $D/prog16.bin /lib/firmware/p1i-dsp/DspStartupCode.bin; then
	echo "host-port read OK (program words match the firmware)"
else
	echo "host-port read MISMATCH:"; od -An -tx2 $D/prog16.bin
	od -An -tx2 -N32 /lib/firmware/p1i-dsp/DspStartupCode.bin
fi
$T save 0x08000000 $D/shared.bin
$T peek data 0 0x8000 $D/data0.bin
$T peek data 0x8800 0x2800 $D/data8800.bin
$T regs >> $D/regs.txt
echo "saved to $D"
