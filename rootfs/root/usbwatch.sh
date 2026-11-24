#!/bin/sh
# usbwatch.sh [SECONDS] -- EXPERIMENT: log the USB clock state while the cable is pulled and
# replugged (2026-11-24: after a handover without the cable, i2c-2 (the USB block's I2C to
# the ISP1301/STOTG04 transceiver) failed for good and USB never came up). Runs detached;
# every 2 s to /media/card/other/usbwatch.log (synced): STOPs, USB_CTRL (bit 0 = USB PLL
# lock), OSC_CTRL (bit 0 = main oscillator stopped), the USB block's clock status, the DSP
# PLL, and the i2c-2 error count from the kernel log.
#
#   ./usbwatch.sh [SECONDS]   (default 180), then pull the cable, wait, replug
S=${1:-180}
LOG=/media/card/other/usbwatch.log
B=$(command -v busybox || echo busybox)
if [ "$USBWATCH_BG" != 1 ]; then
	USBWATCH_BG=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
	echo "logging for $S s to $LOG: pull the cable now, replug after about a minute"
	exit 0
fi
echo "start $(date) uptime $(cut -d' ' -f1 /proc/uptime)" >> $LOG
end=$(( $(date +%s) + S ))
while [ $(date +%s) -lt $end ]; do
	echo "$(cut -d' ' -f1 /proc/uptime) stops=$(cat /sys/module/pnx4008_idle/parameters/stops)" \
	     "usbctrl=$($B devmem 0x40004064) osc=$($B devmem 0x4000404C)" \
	     "clksts=$($B devmem 0x31020FF8) dsppll=$($B devmem 0x400E8060)" \
	     "i2c2err=$(dmesg | grep -c 'i2c-2')" >> $LOG
	sync
	sleep 2
done
echo "end $(date)" >> $LOG
dmesg | grep -i -E "i2c-2|udc|vbus|usb" | tail -20 >> $LOG
sync
