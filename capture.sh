#!/bin/sh
# capture.sh -- run a command on the P1i's serial shell and save its output on the PC.
#
#   ./capture.sh OUTFILE 'COMMAND' [DEVICE]      e.g. ./capture.sh on.txt /root/regdump.sh
#
# Quit the terminal program (picocom, minicom, ...) first: two readers on one port split
# the data between them. DEVICE defaults to /dev/ttyUSB0. The output is shown as it
# arrives and saved without CRs; it stops at an end marker echoed after the command, so
# if the phone hangs, press Ctrl-C (the partial file is kept).
set -e

[ $# -ge 2 ] || { echo "usage: $0 OUTFILE 'COMMAND' [DEVICE]" >&2; exit 1; }
out=$1
cmd=$2
dev=${3:-/dev/ttyUSB0}
marker=__CAPTURE_DONE__

stty -F "$dev" 115200 raw -echo clocal
exec 3<>"$dev"
# The marker is split in the command line so that the shell's echo of it does not match.
printf '%s; echo __CAPTURE_""DONE__\n' "$cmd" >&3
# awk reads the port itself (no tr in front) so the pipeline ends as soon as it exits.
awk -v m="$marker" '{ sub(/\r$/, "") } $0 == m { exit } { print; fflush() }' <&3 | tee "$out"
echo "saved $(wc -l < "$out") lines to $out" >&2
