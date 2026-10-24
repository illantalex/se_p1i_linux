#!/bin/sh
# socdump.sh [FILE] -- read-only dump of SoC blocks that may decide whether the audio DSP can
# reach ARM memory, to compare a handover with the DSP awake against one where Symbian
# powered it down: the general-purpose DMA controller (0x31000000: global registers and
# 8 channels), the interrupt controllers (MIC, SIC1, SIC2), the clock/power block, the
# audio block and the DSP host port (no reply registers: reading clears them).
B=busybox
OUT=${1:-/tmp/socdump.txt}
d() {
	i=0
	while [ $i -lt $2 ]; do
		a=$(($1 + i * 16))
		printf "%08x:" $a
		for k in 0 4 8 12; do
			printf " %08x" $($B devmem $((a + k)) 32)
		done
		echo
		i=$((i + 1))
	done
}
{
	echo "# DMA"; d 0x31000000 32
	echo "# MIC"; d 0x40008000 2
	echo "# SIC1"; d 0x4000C000 2
	echo "# SIC2"; d 0x40010000 2
	echo "# CLK"; d 0x40004000 16
	echo "# AUDIO"; d 0x400E8000 8
	echo "# APBP"
	for r in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c 0x20 0x28 0x30; do
		echo "APBP+$r $($B devmem $((0x400C0000 + r)) 32)"
	done
} > "$OUT"
echo "saved $OUT"
