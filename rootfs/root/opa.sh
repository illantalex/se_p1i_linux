#!/bin/sh
# opa.sh NAME|IID METHOD [ARG...] -- EXPERIMENT: call a method of one of the modem's OPA objects
# (EMP's "Open Platform API": the DB2001 modem's services for the application side), the
# way Symbian's BServer does it, on the session it opened before the handover.
#
# Before the handover, in Symbian: D:\other\opascan.txt present, run regprobe. It writes
# D:\other\opa.txt: one line per BServer proxy, <phys> <IID> <session> <stub> [name]. The
# modem keeps running through the handover, so these stay valid until it is reset.
#
# The request (the modem's handler for type 8, M600 CCPU firmware 0x20303bb6), on CAIF
# channel 22 (0x16, segment flag 0, then the PDU), 32-bit words little endian:
#   8, session, request id, stub address, 0, method, arguments packed (u32 = 4 bytes,
#   u16 = 2, u8 = 1)
# Reply (on channel 22 too): 9, status (0 = done), request id, 4, then results. Unknown session: status code 4;
# stub address not a stub: code 2.
#
# ARG: u32:N, u16:N or u8:N (N decimal or 0x hex). IVibratorDevice (motor on the AB2010's
# VIBR pin, no path from the SoC): 3 = mode (out u8), 4 u32:0|1|2 = set mode, 5 = stop,
# 6 u32:N u8:X = vibrate (N < 0x10000, probably ms; X passed to the vibrator driver).
#   opa.sh IVibratorDevice 6 u32:1000 u8:1
#   opa.sh IVibratorDevice 5
# ILedControlDevice (the indicator LED, on the AB2010's LED pins: 1 = red, 2 = green):
# 3 = number of LEDs (out u32: 2), 4 u8:LED = off, 5 u8:LED u32:ON u16:OFF = blink, ON ms on
# and OFF ms off (OFF 0: a flash of ON ms now and then, not steady light).
#   opa.sh ILedControlDevice 5 u8:2 u32:500 u16:500
#   opa.sh ILedControlDevice 4 u8:2
# IUsbChargingControl (IID 20563885..., what Symbian's BAPhandler StartCharging calls):
# 3 = charging current (out u16, mA), 4 u16:N = set it. IIndicationDeviceManager
# (0d44bf86...): its getters hand out the vibrator, backlight and LED objects, and the modem
# then waits for this side to make a proxy (a type 4 request on channel 21; answer it with
# "p1imodem raw 16 00 05 00 00 00 05 40 00 80 <its request id, 4 bytes>" or the session
# stalls).
#
# p1ibat reads UART3 too: it is stopped for the call and started again afterwards.
[ $# -ge 2 ] || { sed -n '2,34s/^# \{0,1\}//p' "$0"; exit 1; }
NAME=$1
METHOD=$2
shift 2

# the card's first partition, where it is mounted already or mounted here for the read
M=$(awk '$1 == "/dev/mspblk0p1" { print $2; exit }' /proc/mounts)
if [ -z "$M" ]; then
	T=$(mktemp -d)
	mount -o ro /dev/mspblk0p1 "$T" || exit 1
	M=$T
fi
# The scan must be from the Symbian boot before this handover: another boot's stub
# addresses are meaningless to the modem, which dereferences them (one hung it, 2026-10-25)
BOOT=$(($(date +%s) - $(cut -d. -f1 /proc/uptime)))
AGE=$((BOOT - $(stat -c %Y "$M/other/opa.txt")))
if [ "$FORCE" != 1 ] && { [ $AGE -gt 1800 ] || [ $AGE -lt -60 ]; }; then
	echo "other/opa.txt is not from the Symbian boot before this handover ($AGE s before it):"
	echo "run regprobe's scan before handing over (FORCE=1 to use it anyway)"
	[ -n "$T" ] && umount "$T" && rmdir "$T"
	exit 1
fi
LINE=$(tr -d "\r" < "$M/other/opa.txt" | awk -v n="$NAME" '$5 == n || index($2, n) == 1 { print; exit }')
if [ -n "$T" ]; then
	umount "$T"
	rmdir "$T"
fi
[ -n "$LINE" ] || { echo "$NAME not in other/opa.txt"; exit 1; }
SESSION=$(echo "$LINE" | cut -d' ' -f3)
STUB=$(echo "$LINE" | cut -d' ' -f4)
echo "$NAME: session $SESSION stub $STUB"

# little-endian bytes of a 32-bit value
le32() { v=$(($1)); printf "%02x %02x %02x %02x" $((v & 255)) $((v >> 8 & 255)) $((v >> 16 & 255)) $((v >> 24 & 255)); }

PDU="$(le32 8) $(le32 0x$SESSION) $(le32 0x5a00$(printf %02x $(($$ & 255)))) $(le32 0x$STUB) $(le32 0) $(le32 $METHOD)"
for a in "$@"; do
	case $a in
	u32:*) PDU="$PDU $(le32 ${a#u32:})" ;;
	u16:*) v=$((${a#u16:})); PDU="$PDU $(printf "%02x %02x" $((v & 255)) $((v >> 8 & 255)))" ;;
	u8:*) PDU="$PDU $(printf %02x $((${a#u8:} & 255)))" ;;
	*) echo "bad argument $a"; exit 1 ;;
	esac
done

BAT=$(pidof p1ibat)
[ -n "$BAT" ] && kill $BAT && sleep 0.5
p1imodem raw 16 00 $PDU
if [ -n "$BAT" ]; then p1ibat; fi
