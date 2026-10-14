// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * p1ikbd -- P1i keypad to console, the way Symbian does it.
 *
 * Grabs the keypad and jog dial input devices (so the kernel's console keymap no longer sees
 * them) and types characters into the active virtual console with TIOCSTI:
 *
 *   Shift, Alt     act on the next key only; pressed twice they lock (Caps / Alt lock),
 *                  a third press unlocks
 *   Shift, Alt     (Shift then Alt) Ctrl for the next key, e.g. Ctrl-Z
 *   Alt + key      the symbol or red digit printed on the key
 *   .              multi-tap: pressed again within a second it replaces the character by
 *                  the next one in a list of symbols that are not on the keys (_ \ | ~ ...)
 *   Back           Ctrl-C; Shift + Back = Ctrl-D
 *   @ (side key)   Tab (shell completion)
 *   arrows, jog    cursor keys; jog press = Enter
 *
 *   p1ikbd [-f]    -f: stay in the foreground and log keys to stderr
 */

#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MULTITAP_MS	1000

struct key {
	unsigned short code;
	const char *normal, *shift, *alt;
};

/* Letters: shift = upper case; alt = what is printed on the key (red digits on both halves). */
static const struct key keys[] = {
	{ KEY_Q, "q", "Q", "@" }, { KEY_W, "w", "W", "/" },
	{ KEY_E, "e", "E", "1" }, { KEY_R, "r", "R", "1" },
	{ KEY_T, "t", "T", "2" }, { KEY_Z, "z", "Z", "2" },
	{ KEY_U, "u", "U", "3" }, { KEY_I, "i", "I", "3" },
	{ KEY_O, "o", "O", ":" }, { KEY_P, "p", "P", "?" },
	{ KEY_A, "a", "A", "(" }, { KEY_S, "s", "S", ")" },
	{ KEY_D, "d", "D", "4" }, { KEY_F, "f", "F", "4" },
	{ KEY_G, "g", "G", "5" }, { KEY_H, "h", "H", "5" },
	{ KEY_J, "j", "J", "6" }, { KEY_K, "k", "K", "6" },
	{ KEY_L, "l", "L", "'" }, { KEY_BACKSPACE, "\x7f", "\x7f", "\x7f" },
	{ KEY_COMMA, ",", ";", "+" }, { KEY_Y, "y", "Y", "-" },
	{ KEY_X, "x", "X", "7" }, { KEY_C, "c", "C", "7" },
	{ KEY_V, "v", "V", "8" }, { KEY_B, "b", "B", "8" },
	{ KEY_N, "n", "N", "9" }, { KEY_M, "m", "M", "9" },
	{ KEY_DOT, ".", ".", "!" }, { KEY_ENTER, "\r", "\r", "\r" },
	{ KEY_LEFT, "\033[D", "\033[D", "*" }, { KEY_SPACE, " ", " ", "0" },
	{ KEY_RIGHT, "\033[C", "\033[C", "#" },
	{ KEY_UP, "\033[A", "\033[A", "\033[A" }, { KEY_DOWN, "\033[B", "\033[B", "\033[B" },
	{ KEY_BACK, "\003", "\004", "\003" },		/* Ctrl-C, Shift: Ctrl-D */
	{ KEY_EMAIL, "\t", "\t", "\t" },		/* side "@" key: Tab */
};

/* Cycled by repeated presses of "."; the first entry is what a single press gives. */
static const char multitap[] = ".,?!_\\|~`^&%$\";=<>[]{}#*@/:'()+-";

enum mod { MOD_OFF, MOD_ONCE, MOD_LOCK };

static enum mod shift, alt;
static int ctrl_once, verbose;
static int tty = -1;

static void type(const char *s)
{
	for (; *s; s++)
		if (ioctl(tty, TIOCSTI, s) < 0)
			perror("TIOCSTI");
}

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static enum mod next_mod(enum mod m)
{
	return m == MOD_OFF ? MOD_ONCE : m == MOD_ONCE ? MOD_LOCK : MOD_OFF;
}

static void press(unsigned int code)
{
	static long last_dot_ms;
	static unsigned int tap;
	static int dot_series;
	const struct key *k = NULL;
	char buf[2] = "";
	const char *out;
	size_t i;

	if (code == KEY_LEFTSHIFT) {
		shift = next_mod(shift);
		return;
	}
	if (code == KEY_LEFTALT) {
		if (shift == MOD_ONCE) {	/* Shift then Alt: Ctrl for the next key */
			shift = MOD_OFF;
			ctrl_once = 1;
		} else {
			alt = next_mod(alt);
		}
		return;
	}

	/* "." without Alt: multi-tap through the symbol list. */
	if (code == KEY_DOT && alt == MOD_OFF && !ctrl_once) {
		long t = now_ms();

		if (dot_series && t - last_dot_ms < MULTITAP_MS) {
			tap = (tap + 1) % (sizeof(multitap) - 1);
			type("\x7f");			/* replace the previous symbol */
		} else {
			tap = 0;
		}
		dot_series = 1;
		last_dot_ms = t;
		buf[0] = multitap[tap];
		type(buf);
		if (shift == MOD_ONCE)
			shift = MOD_OFF;
		return;
	}
	dot_series = 0;

	for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
		if (keys[i].code == code)
			k = &keys[i];
	if (!k)
		return;

	if (ctrl_once) {
		ctrl_once = 0;
		if (k->normal[0] >= 'a' && k->normal[0] <= 'z' && !k->normal[1]) {
			buf[0] = k->normal[0] & 0x1f;
			type(buf);
			return;
		}
	}

	out = alt != MOD_OFF ? k->alt : shift != MOD_OFF ? k->shift : k->normal;
	if (verbose)
		fprintf(stderr, "key %u shift %d alt %d -> %s\n", code, shift, alt,
			out[0] == '\033' ? "ESC..." : out);
	type(out);

	if (shift == MOD_ONCE)
		shift = MOD_OFF;
	if (alt == MOD_ONCE)
		alt = MOD_OFF;
}

/* Open and grab every input device whose name is one of ours. */
static int open_inputs(struct pollfd *pfd, int max)
{
	static const char *const names[] = { "40050000.keypad", "jog-dial" };
	struct dirent *de;
	DIR *dir;
	int n = 0;

	dir = opendir("/dev/input");
	if (!dir)
		return 0;
	while ((de = readdir(dir)) && n < max) {
		char path[300], name[64] = "";
		size_t i;
		int fd;

		if (strncmp(de->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
			if (!strcmp(name, names[i]))
				break;
		if (i == sizeof(names) / sizeof(names[0]) || ioctl(fd, EVIOCGRAB, 1) < 0) {
			close(fd);
			continue;
		}
		pfd[n].fd = fd;
		pfd[n].events = POLLIN;
		n++;
	}
	closedir(dir);
	return n;
}

int main(int argc, char **argv)
{
	struct pollfd pfd[4];
	int n, i;

	verbose = argc > 1 && !strcmp(argv[1], "-f");

	/* tty0 is whichever virtual console is in front. */
	tty = open("/dev/tty0", O_RDWR | O_NOCTTY);
	if (tty < 0) {
		perror("/dev/tty0");
		return 1;
	}
	n = open_inputs(pfd, 4);
	if (!n) {
		fprintf(stderr, "p1ikbd: no keypad input device found\n");
		return 1;
	}
	if (!verbose && daemon(0, 0) < 0) {
		perror("daemon");
		return 1;
	}

	for (;;) {
		if (poll(pfd, n, -1) < 0)
			continue;
		for (i = 0; i < n; i++) {
			struct input_event ev;

			if (!(pfd[i].revents & POLLIN))
				continue;
			if (read(pfd[i].fd, &ev, sizeof(ev)) != sizeof(ev))
				continue;
			if (ev.type == EV_KEY && ev.value == 1)
				press(ev.code);
		}
	}
}
