#!/bin/sh
# Register snapshot for finding the SUZI audio block: run once after a handover with the
# Symbian FM radio playing and once without, capture both serial logs and diff them.
# Skipped because reads fault: HSTIM 0x40038000 (clock gated), I2C 0x400a0000-0x400affff;
# and the console UART6 0x40098000 (reads would eat input / disturb the driver).

echo "=== state"
devmem 0x4002800C			# GPO_P3 outputs
i2ctransfer -y 1 r32@0x10		# Si4703, from register 0x0a

echo "=== summary"
memdump -s 0x40000000 0x38000
memdump -s 0x4003c000 0x5c000
memdump -s 0x40099000 0x7000
memdump -s 0x400b0000 0x50000
memdump -s 0x31000000 0x100000

echo "=== dumps"
# First radio on/off summary diff (2026-10-13): besides timers/RTC/GPO, these changed:
# 0x40004000 (clock/power), MIC/SIC1/SIC2, 0x40018000, 0x40048000, 0x40080000 (UART3),
# 0x400bc000, 0x400d1000, 0x400e8000. 0x310a0000 is identical; 0x310e0000+ is SRAM with
# boot-to-boot junk.
for r in 0x40004000:0x1000 0x40008000:0x1000 0x4000c000:0x1000 0x40010000:0x1000 \
	 0x40018000:0x1000 0x40048000:0x1000 0x40080000:0x1000 0x400b0000:0x1000 \
	 0x400b4000:0x1000 0x400b8000:0x2000 0x400bc000:0x1000 0x400c0000:0x1000 \
	 0x400d0000:0x4000 0x400d8000:0x1000 0x400e0000:0x1000 0x400e8000:0x1000; do
	echo "--- ${r%:*}"
	memdump ${r%:*} ${r#*:}
done
echo "=== end"
