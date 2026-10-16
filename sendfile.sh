#!/bin/sh
# sendfile.sh -- copy a file from the PC to the P1i over its serial shell (no network needed).
#
#   ./sendfile.sh FILE [PHONE_PATH] [DEVICE]     e.g. ./sendfile.sh rootfs/root/usbpll.sh
#
# PHONE_PATH defaults to /root/<name>, DEVICE to /dev/ttyUSB0. Quit the terminal program
# first (see capture.sh). The file goes over as base64 lines into `base64 -d` on the phone
# (Debian coreutils or BusyBox), so any content survives the terminal; the md5 is checked.
set -e

[ $# -ge 1 ] || { echo "usage: $0 FILE [PHONE_PATH] [DEVICE]" >&2; exit 1; }
file=$1
dst=${2:-/root/$(basename "$1")}
dev=${3:-/dev/ttyUSB0}
here=$(dirname "$0")

stty -F "$dev" 115200 raw -echo clocal
{
	printf "stty -echo; base64 -d > '%s' <<'__SENDFILE_EOF__'\n" "$dst"
	# Slow enough for the phone's 16-byte UART FIFO and a busy shell.
	base64 -w 76 "$file" | while IFS= read -r line; do printf '%s\n' "$line"; sleep 0.02; done
	printf '__SENDFILE_EOF__\nstty echo\n'
} > "$dev"
sleep 0.5
want=$(md5sum < "$file" | cut -d' ' -f1)
"$here/capture.sh" /dev/null "chmod +x '$dst'; md5sum '$dst'" "$dev" | grep -q "$want" &&
	echo "sent $file -> $dst (md5 ok)" || { echo "md5 mismatch or no answer" >&2; exit 1; }
