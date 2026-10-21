#!/bin/sh
# fmstate.sh [DIR] -- save the audio state, e.g. to compare a setup where the FM radio plays
# with one where it does not: the audio block 0x400E8000, the clock block 0x40004000 and the
# GPIO block 0x40028000 (4 KB each), the DSP host port (not the reply registers: reading
# them clears them), the DSP shared buffer and the tuner. Read-only.
cd "$(dirname "$0")"
D=${1:-/root/fmstate}
B=busybox
mkdir -p "$D"
dump() {
	i=0
	: > "$3"
	while [ $i -lt $2 ]; do
		a=$(($1 + i * 16))
		printf "%08x:" $a >> "$3"
		for k in 0 4 8 12; do
			printf " %08x" $($B devmem $((a + k)) 32) >> "$3"
		done
		echo >> "$3"
		i=$((i + 1))
	done
}
dump 0x400E8000 256 "$D/audio.txt"
dump 0x40004000 256 "$D/clk.txt"
dump 0x40028000 256 "$D/gpio.txt"
: > "$D/apbp.txt"
for r in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c 0x20 0x28 0x30; do
	echo "APBP+$r $($B devmem $((0x400C0000 + r)) 32)" >> "$D/apbp.txt"
done
./dsptool save 0x08000000 "$D/shared.bin" > /dev/null
./fm.sh info > "$D/tuner.txt"
uname -v > "$D/kernel.txt"
echo "saved in $D"
