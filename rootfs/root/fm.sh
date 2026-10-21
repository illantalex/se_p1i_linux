#!/bin/sh
# fm.sh on [MHz] | seek [down] | tune MHz | info | off -- the Si4703 FM receiver
# (/dev/radio0, radio-si470x). The headset cable is the antenna, so the headphones must be
# in the Fast-Port (no USB): run it from the serial console.
#
# The driver powers the chip only while /dev/radio0 is open, so "on" keeps it open with a
# background holder; "off" ends it. This tunes the receiver only: its audio reaches the
# headphones through the codec's line input and the DSP, set up by Symbian's FM radio before
# the handover (D:\other\nostream.txt); ALSA control "Audio Source" = FM selects it.
D=/dev/radio0
PID=/run/fm-holder.pid
info() {
	v4l2-ctl -d $D --get-freq --get-tuner 2>&1 |
		grep -E "Frequency for|Signal|audio mode" | sed 's/^[[:space:]]*//'
}
case "$1" in
on)
	[ -f $PID ] && kill -0 "$(cat $PID)" 2>/dev/null ||
		{ sleep 1000000 < $D & echo $! > $PID; sleep 0.5; }
	v4l2-ctl -d $D -c mute=0 -c volume=15 2>/dev/null
	[ -n "$2" ] && v4l2-ctl -d $D --set-freq="$2" >/dev/null
	info ;;
seek)
	dir=1; [ "$2" = down ] && dir=0
	v4l2-ctl -d $D --freq-seek=dir=$dir,wrap=1 2>&1 | grep -v "^$"
	info ;;
tune)
	v4l2-ctl -d $D --set-freq="$2" >/dev/null
	info ;;
info)
	info ;;
off)
	[ -f $PID ] && kill "$(cat $PID)" 2>/dev/null; rm -f $PID ;;
*)
	echo "usage: fm.sh on [MHz] | seek [down] | tune MHz | info | off"; exit 1 ;;
esac
