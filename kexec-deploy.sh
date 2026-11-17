#!/bin/sh
# kexec-deploy.sh -- boot a freshly built kernel on the running P1i without going through
# Symbian: copy build/zImage-p1i to the phone and kexec into it after a clean shutdown.
#
#   ./kexec-deploy.sh [HOST]      (default root@192.168.7.2, over the USB network)
#
# Needs CONFIG_KEXEC in the running kernel and kexec-tools in Debian (apt install
# kexec-tools; answer "No" to letting it handle reboots, so a plain reboot still returns to
# Symbian). The DTB is passed to kexec explicitly: otherwise kexec-tools hands the new
# kernel the running kernel's device tree (/proc/device-tree), which wins over the DTB
# appended to zImage-p1i, so changes to reservations or the command line would not take
# effect. With HANDOVER=<path to se_p1i_linux_handover> its baremetal/p1i_linux.bin is
# copied to the card too, for the next cold start from Symbian.
set -e
HOST=${1:-root@192.168.7.2}
cd "$(dirname "$0")"

# Into RAM (/tmp): USB traffic while the Memory Stick is written kills the USB link (the
# polled Memory Stick driver starves the device controller's DMA: "DMA data overrun").
scp -q build/arch/arm/boot/zImage "$HOST":/tmp/zImage
scp -q build/arch/arm/boot/dts/pnx4008-p1i.dtb "$HOST":/tmp/pnx4008-p1i.dtb
if [ -n "$HANDOVER" ]; then
	scp -q "$HANDOVER/baremetal/p1i_linux.bin" "$HOST":/tmp/p1i_linux.bin
	ssh "$HOST" 'cp /tmp/p1i_linux.bin /media/card/other/p1i_linux.bin && sync && rm /tmp/p1i_linux.bin'
fi
# Without kexec-tools' reboot hook, jump directly: sync and try to remount the root
# read-only (ext4 on the Memory Stick; usually busy, the sync is what counts).
# The connection dies with the old kernel: keepalives end ssh a few seconds later.
ssh -o ServerAliveInterval=2 -o ServerAliveCountMax=3 "$HOST" 'kexec -l /tmp/zImage --dtb=/tmp/pnx4008-p1i.dtb && cp /tmp/zImage /tmp/pnx4008-p1i.dtb /boot/ && echo "kexec: loaded, jumping into it" &&
	sync && (mount -o remount,ro / || true) && nohup sh -c "sleep 1; kexec -e" </dev/null >/dev/null 2>&1 &'
