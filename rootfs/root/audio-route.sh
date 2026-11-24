#!/bin/sh
# audio-route.sh headphones|speaker [VOLUME]
#
# Switch the DSP's playback route between the speaker and the headphones. The ALSA driver
# does the switch ("Playback Route" control, since #155): amplifiers, DAC_ON, filters, the
# outputs and gains as Symbian switches them (regprobe dsptrace 2026-10-18); it also wakes
# the DSP from standby. Before #155 this script did all that itself through dsptool.
#
# VOLUME: percent (the "Playback Volume" control, default 30 = Symbian's speaker gain; it is
# kept across routes and standby). amixer cset name='Playback Volume' N works as well.
case "$1" in
headphones|hp)	R=Headphones ;;
speaker|spk)	R=Speaker ;;
*)
	echo "usage: $0 headphones|speaker [VOLUME]" >&2
	exit 1
	;;
esac
amixer -q cset name='Playback Route' "$R" || exit 1
[ -n "$2" ] && amixer -q cset name='Playback Volume' "$2"
exit 0
