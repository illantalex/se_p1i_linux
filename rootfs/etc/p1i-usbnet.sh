#!/bin/sh
# USB network to the PC (the phone is a CDC Ethernet gadget, see pc-usbnet.sh on the PC):
# phone 192.168.7.2, PC 192.168.7.1 as gateway. Run by /init (or rcS) with the root to
# configure as $1 ("" for the initramfs itself).
R=$1
ip link set usb0 up 2>/dev/null || exit 0
ip addr add 192.168.7.2/24 dev usb0
ip route add default via 192.168.7.1

# A resolv.conf copied from a PC may point at a local resolver (127.0.0.53): replace it.
grep -qs '^nameserver *[0-9]' $R/etc/resolv.conf && ! grep -qs '^nameserver *127\.' $R/etc/resolv.conf ||
	printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' > $R/etc/resolv.conf

# The clock starts from the RTC that Symbian shares (UTC), which is only as right as
# Symbian's clock; apt rejects signatures from the future. Set it by NTP once the PC routes
# (time.cloudflare.com by address: no DNS needed), trying for 10 minutes in the background,
# and write the result to the RTC (Symbian then has it too). A one-shot ntpd does not mark
# the kernel's time as synchronised, so the kernel's own write-back would not do it. Runs
# inside $R so it survives switch_root; /dev only appears there at switch_root, so the RTC
# write waits for it.
BB=/bin/busybox
[ -n "$R" ] && BB=/usr/local/bin/busybox
chroot ${R:-/} $BB sh -c "for i in \$($BB seq 60); do
	if $BB timeout 10 $BB ntpd -q -n -p 162.159.200.1 -p 162.159.200.123 >/dev/null 2>&1; then
		for j in \$($BB seq 30); do [ -c /dev/rtc0 ] && break; $BB sleep 1; done
		$BB hwclock -w -u
		break
	fi
	$BB sleep 10
done" </dev/null >/dev/null 2>&1 &
