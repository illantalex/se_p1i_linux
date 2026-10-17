#!/bin/sh
# /init of the P1i initramfs (build.sh installs it as rootfs/init).
#
# If the Memory Stick has a Linux root on partition 2 (Debian, see mkdebian.sh), switch to
# it; otherwise, or if other/noroot exists on the card's FAT partition, run the BusyBox
# system of this initramfs as before (/sbin/init = BusyBox init, /etc/inittab, rcS).

ROOT=/dev/mspblk0p2

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

fallback() {
	echo "p1i-init: $1, staying in the initramfs"
	umount /newroot 2>/dev/null
	umount /proc /sys /dev 2>/dev/null
	exec /sbin/init
}

# The card is detected and read about 1.3 s after boot: wait up to 3 s for it, then up to
# 2 s more for its partitions.
i=0
while [ ! -b /dev/mspblk0 ] && [ $i -lt 30 ]; do usleep 100000; i=$((i + 1)); done
[ -b /dev/mspblk0 ] || fallback "no Memory Stick"
i=0
while [ ! -b $ROOT ] && [ $i -lt 20 ]; do usleep 100000; i=$((i + 1)); done
[ -b $ROOT ] || fallback "no partition 2 on the Memory Stick"

if mount -o ro /dev/mspblk0p1 /mnt 2>/dev/null; then
	noroot=$([ -e /mnt/other/noroot ] && echo 1)
	umount /mnt
	[ -n "$noroot" ] && fallback "other/noroot on the card"
fi

mount -o rw,noatime $ROOT /newroot || fallback "cannot mount $ROOT"
[ -e /newroot/sbin/init ] || fallback "no /sbin/init on $ROOT"

# Keep the root's copy of our tools (memdump, evdump, p1ikbd, dsptool, gpio*) and the
# firmware from this payload current.
if ! cmp -s /usr/bin/gpiod-multi /newroot/usr/local/bin/gpiod-multi; then
	mkdir -p /newroot/usr/local/bin
	cp /usr/bin/gpiod-multi /newroot/usr/local/bin/
	for t in /usr/bin/*; do
		[ "$(readlink $t)" = gpiod-multi ] && ln -sfn gpiod-multi /newroot/usr/local/bin/${t##*/}
	done
fi
# BusyBox too, for applets Debian lacks (devmem).
cmp -s /bin/busybox /newroot/usr/local/bin/busybox || cp /bin/busybox /newroot/usr/local/bin/
[ -d /lib/firmware ] && mkdir -p /newroot/lib/firmware && cp -a /lib/firmware/. /newroot/lib/firmware/

# Random seed: the ARM926 has no cycle counter for the kernel's jitter entropy, so the pool
# only counted as initialised after ~90 s of interrupts, and sshd's getrandom() held up the
# boot (and the gettys behind it). seedrng credits the seed saved on the card at the last
# boot and stores a fresh one; the very first boot still waits.
mkdir -p /newroot/var/lib/seedrng
seedrng -d /newroot/var/lib/seedrng

# USB network to the PC: address, route, DNS, clock (see /etc/p1i-usbnet.sh).
/etc/p1i-usbnet.sh /newroot

# The keypad daemon keeps running across switch_root: the display console gets typed on
# from the first getty on.
p1ikbd

# Debian checks the root while it is still read-only, then remounts it read-write.
mount -o remount,ro /newroot
echo "p1i-init: switching to $ROOT, $(cut -d' ' -f1 /proc/uptime)s after boot"
umount /proc /sys
mount --move /dev /newroot/dev
exec switch_root /newroot /sbin/init
