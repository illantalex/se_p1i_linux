#!/bin/sh
# pc-usbnet.sh -- on the PC: bring up the USB network to the P1i and share the PC's
# internet connection with it (NAT), so apt works on the phone. Run as root after plugging
# the phone in:
#
#   sudo ./pc-usbnet.sh [INTERFACE]      (default enx025031000001, the phone's fixed MAC)
#
# The phone sets itself up as 192.168.7.2 with this PC (192.168.7.1) as gateway, see
# rootfs/etc/p1i-usbnet.sh. Undo with a reboot or: sudo ./pc-usbnet.sh INTERFACE stop
set -e

IF=${1:-enx025031000001}
NET=192.168.7.0/24

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
ip link show "$IF" >/dev/null 2>&1 || { echo "no interface $IF (phone plugged in, Linux up?)"; exit 1; }
OUT=$(ip route show default | awk '{ print $5; exit }')
[ -n "$OUT" ] || { echo "no default route on this PC"; exit 1; }

if [ "$2" = stop ]; then
	iptables -t nat -D POSTROUTING -s $NET -o "$OUT" -j MASQUERADE 2>/dev/null || true
	iptables -D FORWARD -i "$IF" -o "$OUT" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i "$OUT" -o "$IF" -m state --state RELATED,ESTABLISHED -j ACCEPT \
		2>/dev/null || true
	ip addr flush dev "$IF"
	exit 0
fi

# Keep NetworkManager from running DHCP on it and flushing the address.
command -v nmcli >/dev/null && nmcli device set "$IF" managed no 2>/dev/null || true
ip addr replace 192.168.7.1/24 dev "$IF"
ip link set "$IF" up

sysctl -q -w net.ipv4.ip_forward=1
# Idempotent: -C checks for the rule first. FORWARD rules are needed where Docker set the
# chain's policy to DROP.
iptables -t nat -C POSTROUTING -s $NET -o "$OUT" -j MASQUERADE 2>/dev/null ||
	iptables -t nat -A POSTROUTING -s $NET -o "$OUT" -j MASQUERADE
iptables -C FORWARD -i "$IF" -o "$OUT" -j ACCEPT 2>/dev/null ||
	iptables -I FORWARD -i "$IF" -o "$OUT" -j ACCEPT
iptables -C FORWARD -i "$OUT" -o "$IF" -m state --state RELATED,ESTABLISHED -j ACCEPT \
	2>/dev/null ||
	iptables -I FORWARD -i "$OUT" -o "$IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "$IF up as 192.168.7.1, phone 192.168.7.2 routed to the internet via $OUT"
ping -c 1 -W 2 192.168.7.2 >/dev/null && echo "phone answers" || echo "phone does not answer (yet)"
