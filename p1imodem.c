// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * p1imodem -- experiments with the P1i's DB2001 modem over the CAIF link Symbian left on
 * UART3: send raw CAIF frames, try to open an AT channel.
 *
 * After the handover the modem is still in CAIF mode on UART3 (0x40080000, 115200 8N1;
 * frames: 16-bit LE length of payload + FCS, payload, FCS-16 (PPP); no STX). This uses the
 * UART as Symbian set it up, through /dev/mem. Symbian keeps a break on the TX line while
 * it does not talk to the modem: clearing it wakes the modem, which pulls CTS (GPI_05) low;
 * replies on the control channel come once the break is set again.
 *
 * The control channel 0 speaks Linux's CAIF control protocol (net/caif/cfctrl.c): ENUM
 * (00 03 01) is answered with 00 23 01, RADIO_SET (00 08 <0|1>) with 00 28 <0|1> and
 * switches the radio (flight mode; p1ibat does that). LINK_SETUP of an AT channel
 * (00 00 (chtype << 4) | 1, (priority << 3) | phyid, endpoint) was refused (00 30 ...) for
 * every channel type and endpoint tried, as was every other service (DECM, video, debug,
 * datagram with connection ids 0-22, RFM, utility): the channels seem fixed by Symbian's
 * AT*SECAIF setup. Of channels 1-31, only 1 and 2 answer data, and they are loopbacks: they
 * return whatever they get, even plain text ("ABC"), with the first byte set to 0 and bit 7
 * of the fifth byte cleared (0c 00 00 00 99 ... -> 0c 00 00 00 19 ...).
 *
 * The OPA traffic (EMP's proxy/stub manager, PSM) runs over a CAIF DECM link on channel 22
 * in both directions: frame = 0x16, segment flag (0 = last), PSM PDU (at most 256 bytes per
 * segment). A PDU starts with a u32 type; the modem's notifications are type 12, one-way
 * calls: [12][object id][length][method][arguments]. Read from the M600 CCPU firmware
 * (same platform): 2/3 query interface, 4/5 create instance, 8/9 invoke ([8][stub id]
 * [request id][interface pointer][?], method at offset 20), 13/14 add reference, 15/16
 * release. An invoke needs the stub id and interface pointer Symbian got at start-up.
 *
 * After "reset" (tried 2026-10-18; the phone keeps running: BB_RST# only resets the DB2001,
 * not the AB2010 power chip) the modem stays silent: no boot output and no answer to AT on
 * UART3 (with or without RTS = GPO_17 high), nothing on HS UART2 at 115200 or 928k (HS
 * UART1 is in loopback). It keeps CTS low and put one break on HS UART2. It probably waits
 * for a start-up handshake from the application side (bridgedrv.ldd); booting Symbian
 * again restores the CAIF link.
 *
 * Stop p1ibat first (killall p1ibat): only one reader of UART3 works at a time.
 *
 *   p1imodem listen SECONDS                print every frame received
 *   p1imodem sweep FROM TO HEX...          send the payload HEX (after the channel byte) to
 *                                          every channel FROM..TO, 0.6 s of replies each
 *   p1imodem reset                         reset the modem (BB_RST# = GPO_07 low for
 *                                          100 ms): it restarts in AT mode, not CAIF
 *   p1imodem text "AT" [SECONDS]           plain text: send the line (+ CR) with the break
 *                                          off, print what comes back (default 3 s); the
 *                                          break stays off
 *   p1imodem raw HEX...                    send one frame with this payload (first byte =
 *                                          channel) and print the replies for 4 s
 *   p1imodem send HEX...                   the same, replies for 0.3 s only (for calls in
 *                                          quick succession)
 *   p1imodem at "AT+CFUN?" [CHTYPE PRIO PHYID]
 *                                          open an AT channel, send the command, print
 *                                          the replies for 10 s (default 2 15 1: plain AT,
 *                                          normal priority, physical link 1)
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define U16_RBR		0x00
#define U16_THR		0x00
#define U16_LCR		0x0c
#define U16_LSR		0x14
#define U16_MSR		0x18
#define U16_LCR_BREAK	(1 << 6)
#define U16_LSR_DR	(1 << 0)
#define U16_LSR_THRE	(1 << 5)

static volatile uint32_t *u3, *gpio;
static double t0;
static int setup_reply = -1;	/* channel from a LINK_SETUP reply, -2 = rejected */

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9 - t0;
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

static void handle_payload(const uint8_t *p, int n)
{
	int i, text = n > 2 && p[0] != 0 && p[0] != 22;

	printf("%8.3f rx ch%d:", now(), p[0]);
	for (i = 1; i < n; i++)
		printf(" %02x", p[i]);
	if (text) {
		/* AT replies: show the text too */
		printf("  \"");
		for (i = 2; i < n; i++)
			putchar(p[i] >= 0x20 && p[i] < 0x7f ? p[i] : '.');
		printf("\"");
	}
	printf("\n");
	if (p[0] == 0 && n >= 2 && (p[1] & 0x0f) == 0x00 && (p[1] & 0x20))
		setup_reply = p[1] & 0x10 ? -2 : p[n - 1];
}

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
			if (fcs16(buf + 2, flen - 2) == (buf[flen] | buf[flen + 1] << 8)) {
				handle_payload(buf + 2, flen - 2);
				len -= flen + 2;
				memmove(buf, buf + flen + 2, len);
				continue;
			}
		}
		len--;
		memmove(buf, buf + 1, len);
	}
}

/*
 * Receive for SECONDS, or until a LINK_SETUP reply if stop_on_setup. The modem asks to send
 * by pulling CTS (GPI_05) low while our break is on: answer with a short wake-up (break off
 * for 20 ms), or its replies stay queued.
 */
static void receive(double seconds, int stop_on_setup)
{
	double end = now() + seconds, woke = 0;

	while (now() < end) {
		while (u3[U16_LSR / 4] & U16_LSR_DR)
			handle_byte(u3[U16_RBR / 4]);
		if ((u3[U16_LCR / 4] & U16_LCR_BREAK) && !(gpio[0] & (1 << 5)) &&
		    now() - woke > 0.5) {
			uint32_t lcr = u3[U16_LCR / 4];
			double t;

			woke = now();
			u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
			for (t = now(); now() - t < 0.02; )
				while (u3[U16_LSR / 4] & U16_LSR_DR)
					handle_byte(u3[U16_RBR / 4]);
			u3[U16_LCR / 4] = lcr;
		}
		if (stop_on_setup && setup_reply != -1)
			return;
		usleep(500);
	}
}

static void send_frame(const uint8_t *payload, int n)
{
	uint8_t frame[300];
	uint16_t fcs = fcs16(payload, n);
	int i, len = n + 2;

	frame[0] = len & 0xff;
	frame[1] = len >> 8;
	memcpy(frame + 2, payload, n);
	frame[2 + n] = fcs & 0xff;
	frame[3 + n] = fcs >> 8;
	printf("%8.3f tx ch%d:", now(), payload[0]);
	for (i = 1; i < n; i++)
		printf(" %02x", payload[i]);
	printf("\n");
	for (i = 0; i < n + 4; i++) {
		while (!(u3[U16_LSR / 4] & U16_LSR_THRE))
			;
		u3[U16_THR / 4] = frame[i];
	}
}

int main(int argc, char **argv)
{
	uint32_t lcr;
	int fd;

	if (argc < 3 && !(argc == 2 && !strcmp(argv[1], "reset"))) {
		fprintf(stderr, "usage: %s listen SECONDS | raw HEX... | reset | text LINE [SECONDS] | at COMMAND [CHTYPE PRIO PHYID]\n",
			argv[0]);
		return 1;
	}
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	u3 = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x40080000);
	gpio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x40028000);
	if (u3 == MAP_FAILED || gpio == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	t0 = 0;
	t0 = now();

	if (!strcmp(argv[1], "reset")) {
		/* P3_OUTP_CLR / P3_OUTP_SET, bit 7 = GPO_07 = BB_RST# */
		gpio[0x08 / 4] = 1 << 7;
		usleep(100000);
		gpio[0x04 / 4] = 1 << 7;
		printf("modem reset\n");
		return 0;
	}
	if (!strcmp(argv[1], "text")) {
		double end;
		int i, col = 0;

		u3[U16_LCR / 4] = u3[U16_LCR / 4] & ~U16_LCR_BREAK;
		while (u3[U16_LSR / 4] & U16_LSR_DR)
			(void)u3[U16_RBR / 4];
		for (i = 0; argv[2][i] || i == (int)strlen(argv[2]); i++) {
			while (!(u3[U16_LSR / 4] & U16_LSR_THRE))
				;
			u3[U16_THR / 4] = argv[2][i] ? argv[2][i] : '\r';
			if (!argv[2][i])
				break;
		}
		end = now() + (argc > 3 ? atof(argv[3]) : 3);
		while (now() < end) {
			while (u3[U16_LSR / 4] & U16_LSR_DR) {
				uint8_t c = u3[U16_RBR / 4];

				if (c == '\n' || col > 70) {
					putchar('\n');
					col = 0;
				}
				if (c >= 0x20 && c < 0x7f)
					putchar(c);
				else if (c != '\n')
					printf("<%02x>", c);
				col++;
			}
			usleep(500);
		}
		putchar('\n');
		return 0;
	}
	if (!strcmp(argv[1], "listen")) {
		receive(atof(argv[2]), 0);
		return 0;
	}
	if (!strcmp(argv[1], "sweep") && argc >= 5) {
		uint8_t payload[256];
		int n, ch, from = strtol(argv[2], NULL, 0), to = strtol(argv[3], NULL, 0);

		for (n = 0; n < argc - 4 && n + 1 < (int)sizeof(payload); n++)
			payload[n + 1] = strtoul(argv[n + 4], NULL, 16);
		/* restored at the end with the break on: the idle state (and replies need it) */
		lcr = u3[U16_LCR / 4] | U16_LCR_BREAK;
		for (ch = from; ch <= to; ch++) {
			payload[0] = ch;
			u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
			receive(0.05, 0);
			send_frame(payload, n + 1);
			receive(0.05, 0);
			u3[U16_LCR / 4] = lcr;
			receive(0.6, 0);
		}
		return 0;
	}
	if (!strcmp(argv[1], "raw") || !strcmp(argv[1], "send")) {
		uint8_t payload[256];
		int n;

		for (n = 0; n < argc - 2 && n < (int)sizeof(payload); n++)
			payload[n] = strtoul(argv[n + 2], NULL, 16);
		/* restored at the end with the break on: the idle state (and replies need it) */
		lcr = u3[U16_LCR / 4] | U16_LCR_BREAK;
		u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
		receive(0.2, 0);
		send_frame(payload, n);
		/* The modem answers control requests only once the break is back */
		receive(0.05, 0);
		u3[U16_LCR / 4] = lcr;
		receive(strcmp(argv[1], "send") ? 4 : 0.3, 0);
		return 0;
	}
	if (strcmp(argv[1], "at")) {
		fprintf(stderr, "unknown command %s\n", argv[1]);
		return 1;
	}

	{
		int chtype = argc > 3 ? atoi(argv[3]) : 2;
		int prio = argc > 4 ? atoi(argv[4]) : 15;
		int phyid = argc > 5 ? atoi(argv[5]) : 1;
		uint8_t setup[] = { 0, 0x00, (chtype << 4) | 1, (prio << 3) | phyid, 0 };
		uint8_t at[256];
		int n, ch;

		/* restored at the end with the break on: the idle state (and replies need it) */
		lcr = u3[U16_LCR / 4] | U16_LCR_BREAK;
		printf("LCR 0x%02x MSR 0x%02x: clearing the break\n", lcr, u3[U16_MSR / 4]);
		u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
		receive(0.2, 0);	/* let the modem wake up, show what it says */

		send_frame(setup, sizeof(setup));
		receive(0.05, 0);
		u3[U16_LCR / 4] = lcr;	/* the reply comes once the break is back */
		receive(5, 1);
		if (setup_reply < 0) {
			printf("no channel: %s\n", setup_reply == -2 ? "rejected" : "no reply");
		} else {
			ch = setup_reply;
			printf("AT channel %d\n", ch);
			at[0] = ch;
			at[1] = 0x00;
			n = snprintf((char *)at + 2, sizeof(at) - 2, "%s\r", argv[2]);
			u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
			receive(0.2, 0);
			send_frame(at, n + 2);
			receive(0.05, 0);
			u3[U16_LCR / 4] = lcr;
			receive(10, 0);
		}
		u3[U16_LCR / 4] = lcr;
		printf("LCR restored to 0x%02x\n", lcr);
	}
	return 0;
}
