#!/bin/sh
# Build a minimal Debian armel root file system for the P1i as a tarball, to be unpacked
# onto the Memory Stick's Linux partition (see README). Runs on the PC, as root:
#
#   sudo ./mkdebian.sh [SUITE]          (default: trixie) -> debian-armel-SUITE.tar.gz
#
# Needs mmdebstrap and qemu user-mode emulation for ARM registered with binfmt_misc
# (Debian/Ubuntu: apt install mmdebstrap qemu-user-binfmt, or qemu-user-static on older
# releases), so that the packages' scripts run here and nothing is left for the phone.
#
# The result boots with sysvinit (systemd is too heavy for 208 MHz / 128 MB) and gives root
# shells without a password on the display (tty1) and the serial console (ttyS0).
set -e

SUITE=${1:-trixie}
OUT=debian-armel-$SUITE.tar.gz
PACKAGES=sysvinit-core,e2fsprogs,dosfstools,procps,iproute2,nano,less,ncurses-term,psmisc

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
command -v mmdebstrap >/dev/null || { echo "mmdebstrap is not installed"; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] ||
	{ echo "no qemu-arm binfmt handler (install qemu-user-binfmt)"; exit 1; }

mmdebstrap --arch=armel --variant=minbase --include=$PACKAGES \
	--customize-hook='chroot "$1" passwd -d root' \
	--customize-hook='echo p1i > "$1/etc/hostname"' \
	--customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tp1i\n" > "$1/etc/hosts"' \
	--customize-hook='mkdir -p "$1/media/card"' \
	--customize-hook='cat > "$1/etc/fstab" <<EOF
# <device>        <mount point> <type> <options>                         <dump> <pass>
/dev/mspblk0p2    /             ext4   defaults,noatime                  0      1
/dev/mspblk0p1    /media/card   vfat   noatime,nofail,utf8,shortname=mixed 0    0
tmpfs             /tmp          tmpfs  defaults,nosuid,nodev             0      0
EOF' \
	--customize-hook='sed -i -e "/^[1-6]:/d" -e "/^#T0/d" "$1/etc/inittab" &&
		printf "%s\n" \
		"1:2345:respawn:/sbin/agetty --autologin root --noclear tty1 linux" \
		"T0:2345:respawn:/sbin/agetty --autologin root -L 115200 ttyS0 vt100" \
		>> "$1/etc/inittab"' \
	--customize-hook='echo "export PATH=/usr/local/bin:\$PATH" > "$1/etc/profile.d/p1i.sh"' \
	"$SUITE" "$OUT"

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
