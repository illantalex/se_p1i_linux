#!/bin/sh
# kexec-deploy.sh -- boot a freshly built kernel on the running P1i without going through
# Symbian: copy build/zImage-p1i to the phone and kexec into it after a clean shutdown.
#
#   ./kexec-deploy.sh [HOST]      (default root@192.168.7.2, over the USB network)
#
# Needs CONFIG_KEXEC in the running kernel and kexec-tools in Debian (apt install
# kexec-tools; answer "No" to letting it handle reboots, so a plain reboot still returns to
# Symbian). The new kernel takes its command line and reservations from its own appended DTB. With HANDOVER=<path to se_p1i_linux_handover> its baremetal/p1i_linux.bin is
# copied to the card too, for the next cold start from Symbian.
set -e
HOST=${1:-root@192.168.7.2}
cd "$(dirname "$0")"

scp -q build/zImage-p1i "$HOST":/boot/zImage-p1i
if [ -n "$HANDOVER" ]; then
	scp -q "$HANDOVER/baremetal/p1i_linux.bin" "$HOST":/media/card/other/p1i_linux.bin
fi
# Without kexec-tools' reboot hook, jump directly: sync and try to remount the root
# read-only (ext4 on the Memory Stick; usually busy, the sync is what counts).
# The connection dies with the old kernel: keepalives end ssh a few seconds later.
ssh -o ServerAliveInterval=2 -o ServerAliveCountMax=3 "$HOST" 'kexec -l /boot/zImage-p1i && echo "kexec: loaded, jumping into it" &&
	sync && (mount -o remount,ro / || true) && nohup sh -c "sleep 1; kexec -e" </dev/null >/dev/null 2>&1 &'
