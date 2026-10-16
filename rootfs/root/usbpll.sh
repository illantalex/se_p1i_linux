#!/bin/bash
# USB clock experiment (PNX4008), version 3: the USB PLL runs from the main 13 MHz
# oscillator (/13 = 1 MHz), which Symbian keeps stopped (OSC_CTRL bit 0) while running from
# PLL397. Start it first, then Symbian's sequence step by step, and after it a
# command to the USB device engine, which only completes if the engine has its 48 MHz clock.
B=/usr/local/bin/busybox
[ -x $B ] || B=busybox
r() { $B devmem $1; }
w() { $B devmem $1 32 $2; }
show() { echo "  USB_CTRL $(r 0x40004064)  CLK_CTRL $(r 0x31020FF4)  CLK_STS $(r 0x31020FF8)"; }

echo "1. as booted"; show; echo "  OSC_CTRL $(r 0x4000404C)  SYSCLK_CTRL $(r 0x40004050)"
echo "0. start the main oscillator"
w 0x4000404C $(( $(r 0x4000404C) & ~1 )); sleep 0.1
echo "  OSC_CTRL $(r 0x4000404C)  SYSCLK_CTRL $(r 0x40004050)"
echo "2. AHB clock request (bit 24)"
w 0x40004064 $(( $(r 0x40004064) | 0x1000000 )); show
echo "3. device clock request + PLL power + input (0x4300be)"
w 0x40004064 $(( $(r 0x40004064) | 0x4300be ))
for i in 1 2 3 4 5; do sleep 0.2; echo "  +${i}00 ms: USB_CTRL $(r 0x40004064)"; done
echo "4. PLL output to the block (bit 18)"
w 0x40004064 $(( $(r 0x40004064) | 0x40000 )); show
echo "5. block clocks: device (2) + AHB master (0x10)"
w 0x31020FF4 $(( $(r 0x31020FF4) | 0x12 )); sleep 0.1; show
if [ $(( $(r 0x40004064) & 1 )) = 0 ]; then echo "no PLL lock: skipping the engine test (it would freeze)"; exit 1; fi
echo "6. engine command test (Read Device Status)"
w 0x31020208 0x30
w 0x31020210 0x00FE0500
sleep 0.1
echo "  DevIntSt $(r 0x31020200)   (bit 4 set = the engine runs)"
