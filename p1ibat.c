// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * p1ibat -- battery level from the P1i's modem, with low battery warnings and a clean
 * shutdown when it is empty.
 *
 * The DB2001 modem charges the battery and measures it. After the handover it is still in
 * CAIF mode on UART3 (0x40080000, 115200 8N1, set up by Symbian) and keeps sending OPA
 * notifications on CAIF channel 22 whenever a value changes. The battery level is one of
 * them: the percentage Symbian shows. This daemon reads UART3's receive FIFO through
 * /dev/mem without touching any UART register (the link stays exactly as Symbian left
 * it), decodes the frames and acts on the level:
 *
 *   /run/p1i-battery      level=<percent or "unknown">, plus every notification value seen
 *                         (raw, hex)
 *   20% and 10%           a warning in the kernel log (screen and serial console)
 *   <= 1% for 60 s        poweroff (the batteries' own 0% is not empty yet)
 *
 * The modem only reports changes, so the level is unknown until the first report; the last
 * report before the handover is often still waiting in the FIFO. Only one reader of UART3
 * can work at a time: stop p1ibat before using uartspy.
 *
 * CAIF serial frame: length (16-bit LE, payload + 2) | payload | FCS-16 (PPP) of the payload.
 * Payload on channel 22: 0x16, 0x00, then 32-bit LE words: 12 (header size), message id,
 * length of the rest, notification type, value. The level is message 0x04 (repeated as
 * 0x21), type 3. Charger events (types 6, 7, 8, 10 of message 0x04) are recorded raw.
 *
 *   p1ibat [-f]     -f: stay in the foreground and print every frame
 */

#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define UART3_PHYS	0x40080000
#define U16_RBR		0x00
#define U16_LSR		0x14
#define U16_LSR_DR	(1 << 0)
#define U16_LSR_OE	(1 << 1)

#define CAIF_CH_NOTIFY	22
#define MSG_BATTERY	0x04
#define MSG_BATTERY2	0x21
#define TYPE_LEVEL	3
#define NTYPES		16

#define STATUS_FILE	"/run/p1i-battery"
#define POLL_US		2000	/* the 64-byte FIFO fills in 5.5 ms at 115200 */
#define EMPTY_LEVEL	1
#define EMPTY_SECONDS	60

static const int warn_levels[] = { 20, 10 };
#define NWARN (sizeof(warn_levels) / sizeof(warn_levels[0]))

static int verbose;
static int level = -1;		/* -1: no report yet */
static long values[2][NTYPES];	/* last value per type: [0] message 0x04, [1] 0x20 */
static int seen[2][NTYPES];
static unsigned long overruns;

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Kernel log: shown on every console (the display and UART6) */
static void kmsg(const char *fmt, ...)
{
	char buf[200];
	va_list ap;
	int fd, n;

	n = snprintf(buf, sizeof(buf), "<4>p1ibat: ");
	va_start(ap, fmt);
	vsnprintf(buf + n, sizeof(buf) - n, fmt, ap);
	va_end(ap);
	fd = open("/dev/kmsg", O_WRONLY);
	if (fd >= 0) {
		/* Nothing to do if it fails: there is nowhere else to report */
		(void)!write(fd, buf, strlen(buf));
		close(fd);
	}
	if (verbose)
		fprintf(stderr, "%s\n", buf + 3);
}

static void write_status(void)
{
	static const char *const msgname[2] = { "battery", "msg20" };
	FILE *f = fopen(STATUS_FILE ".tmp", "w");
	int m, t;

	if (!f)
		return;
	if (level < 0)
		fprintf(f, "level=unknown\n");
	else
		fprintf(f, "level=%d\n", level);
	for (m = 0; m < 2; m++)
		for (t = 0; t < NTYPES; t++)
			if (seen[m][t])
				fprintf(f, "%s_type%d=0x%lx\n", msgname[m], t,
					(unsigned long)(uint32_t)values[m][t]);
	fprintf(f, "overruns=%lu\n", overruns);
	if (fclose(f) == 0)
		rename(STATUS_FILE ".tmp", STATUS_FILE);
}

static uint16_t fcs16(const uint8_t *p, int n)
{
	uint16_t fcs = 0xffff;
	int i;

	while (n--) {
		fcs ^= *p++;
		for (i = 0; i < 8; i++)
			fcs = fcs & 1 ? (fcs >> 1) ^ 0x8408 : fcs >> 1;
	}
	return fcs;
}

static uint32_t le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

/* One CAIF payload (without length and FCS) */
static void handle_payload(const uint8_t *p, int n)
{
	uint32_t msg, type, value = 0;
	int m, i;

	if (verbose) {
		fprintf(stderr, "%9.3f frame:", now());
		for (i = 0; i < n; i++)
			fprintf(stderr, " %02x", p[i]);
		fprintf(stderr, "\n");
	}
	if (n < 2 + 16 || p[0] != CAIF_CH_NOTIFY || le32(p + 2) != 12)
		return;
	msg = le32(p + 6);
	type = le32(p + 14);
	if (n >= 2 + 20)
		value = le32(p + 18);
	if (msg == MSG_BATTERY || msg == MSG_BATTERY2)
		m = 0;
	else if (msg == 0x20 || msg == 0x08)
		m = 1;
	else
		return;
	if (type < NTYPES) {
		values[m][type] = (int32_t)value;
		seen[m][type] = 1;
	}
	if (m == 0 && type == TYPE_LEVEL && value <= 100)
		level = value;
	write_status();
}

/* Stream of received bytes -> frames, resynchronising on bad lengths and checksums */
static void handle_byte(uint8_t c)
{
	static uint8_t buf[600];
	static int len;
	int flen;

	buf[len++] = c;
	for (;;) {
		if (len < 2)
			return;
		flen = buf[0] | buf[1] << 8;
		if (flen >= 4 && flen <= (int)sizeof(buf) - 2) {
			if (len < flen + 2)
				return;
			if (fcs16(buf + 2, flen - 2) ==
			    (buf[flen] | buf[flen + 1] << 8)) {
				handle_payload(buf + 2, flen - 2);
				len -= flen + 2;
				memmove(buf, buf + flen + 2, len);
				continue;
			}
		}
		/* Not a frame start: drop one byte and look again */
		len--;
		memmove(buf, buf + 1, len);
	}
}

int main(int argc, char **argv)
{
	volatile uint32_t *u3;
	unsigned int warned = 0;
	double empty_since = 0, status_at = 0;
	int fd, last_level = -2;
	unsigned int i;

	if (argc > 1 && !strcmp(argv[1], "-f"))
		verbose = 1;
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	u3 = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, UART3_PHYS);
	if (u3 == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	if (!verbose && daemon(0, 0) < 0) {
		perror("daemon");
		return 1;
	}
	write_status();

	for (;;) {
		uint32_t lsr;

		while ((lsr = u3[U16_LSR / 4]) & U16_LSR_DR) {
			if (lsr & U16_LSR_OE)
				overruns++;
			handle_byte(u3[U16_RBR / 4]);
		}

		if (level != last_level) {
			last_level = level;
			if (verbose)
				fprintf(stderr, "level %d%%\n", level);
			for (i = 0; i < NWARN; i++) {
				if (level >= 0 && level <= warn_levels[i] &&
				    !(warned & 1 << i)) {
					kmsg("battery low: %d%%\n", level);
					warned |= 1 << i;
				} else if (level >= warn_levels[i] + 5) {
					/* Charged again: warn again next time */
					warned &= ~(1 << i);
				}
			}
			if (level >= 0 && level <= EMPTY_LEVEL) {
				if (!empty_since) {
					empty_since = now();
					kmsg("battery empty (%d%%): powering off in %d s\n",
					     level, EMPTY_SECONDS);
				}
			} else if (empty_since) {
				empty_since = 0;
				kmsg("battery at %d%% again: power off cancelled\n", level);
			}
		}
		/* Also rewrite the status now and then: /run may be mounted after we start */
		if (now() - status_at >= 60) {
			status_at = now();
			write_status();
		}
		if (empty_since && now() - empty_since >= EMPTY_SECONDS) {
			kmsg("battery empty: powering off\n");
			execl("/sbin/poweroff", "poweroff", (char *)NULL);
			execlp("poweroff", "poweroff", (char *)NULL);
			kmsg("poweroff failed\n");
			empty_since = 0;
		}
		usleep(POLL_US);
	}
}
