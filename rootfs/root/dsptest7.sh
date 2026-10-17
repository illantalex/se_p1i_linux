#!/bin/sh
# DSP audio experiment 7: Symbian's live FEV, read from its shared buffer during WAV playback
# (0x810: 0000 0100 00CF CAB4 0000 0000). The suzifev.h vector has 0x33CC in word 4, the
# block power-off bits (SIO_Off etc.), which stops the DSP's serial interface to the DAC.
# Area 0 carries 44.1 kHz 16-bit stereo, 504 frames (2016 bytes) per half. Headphones on.
F=/lib/firmware/p1i-dsp
SH=0x08000000
FEV="0x0000 0x0100 0x00CF 0xCAB4 0x0000 0x0000"

gpioset -z -c gpiochip6 14=1 15=1 16=1 2>/dev/null

dsptool boot $F/DspStartupCode.bin $F/DspStartupData.bin $SH | grep -E "msg 11"
dsptool fev $SH $FEV | grep ^msg
echo "== semaphores after the FEV (2 s)"
dsptool sem 2000 | tail -4
echo "== tone through area 0, 2016-byte halves, 8 s"
dsptool tone $SH 0 2016 2 2 8000
dsptool regs
