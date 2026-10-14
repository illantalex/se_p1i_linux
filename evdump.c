// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * evdump -- print input events from /dev/input/eventN (a minimal evtest; BusyBox has
 * none). Shows key presses with their keycode and the scancode the driver reported, which
 * is what is needed to write a keymap.
 *
 *   evdump [/dev/input/event0]
 */

#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/input/event0";
	struct input_event ev;
	unsigned int scan = 0;
	int have_scan = 0;
	char name[64] = "";
	int fd;

	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		perror(dev);
		return 1;
	}
	ioctl(fd, EVIOCGNAME(sizeof(name)), name);
	printf("%s: %s\n", dev, name);

	while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
		switch (ev.type) {
		case EV_MSC:
			if (ev.code == MSC_SCAN) {
				scan = ev.value;
				have_scan = 1;
			}
			break;
		case EV_KEY:
			if (have_scan)
				printf("key %3u (0x%03x) %-7s scancode 0x%02x\n", ev.code, ev.code,
				       ev.value == 1 ? "press" : ev.value == 0 ? "release" : "repeat",
				       scan);
			else
				printf("key %3u (0x%03x) %s\n", ev.code, ev.code,
				       ev.value == 1 ? "press" : ev.value == 0 ? "release" : "repeat");
			have_scan = 0;
			break;
		case EV_SYN:
			/* A scancode without a key event: the keymap has no entry for it. */
			if (have_scan)
				printf("unmapped        scancode 0x%02x\n", scan);
			have_scan = 0;
			break;
		default:
			printf("type %u code %u value %d\n", ev.type, ev.code, ev.value);
		}
		fflush(stdout);
	}
	return 0;
}
