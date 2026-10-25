// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * p1ibat -- battery level from the P1i's modem, with low battery warnings and a clean
 * shutdown when it is empty; switches the modem's radio off and on (flight mode).
 *
 * The DB2001 modem charges the battery and measures it. After the handover it is still in
 * CAIF mode on UART3 (0x40080000, 115200 8N1, set up by Symbian) and keeps sending OPA
 * notifications on CAIF channel 22 whenever a value changes. The battery level is one of
 * them: the percentage Symbian shows. This daemon reads UART3's receive FIFO through
 * /dev/mem, using the UART exactly as Symbian left it, decodes the frames and acts on the
 * level:
 *
 *   /run/p1i-battery      level=<percent or "unknown">, plus every notification value seen
 *                         (raw, hex)
 *   20% and 10%           a warning in the kernel log (screen and serial console)
 *   <= 1% for 60 s        poweroff (the batteries' own 0% is not empty yet)
 *   radio                 off or on on request; radio=on/off/unknown in the status file
 *
 * The modem only reports changes, so the level is unknown until the first report; the last
 * report before the handover is often still waiting in the FIFO. Only one reader of UART3
 * can work at a time: stop p1ibat before using uartspy.
 *
 * CAIF serial frame: length (16-bit LE, payload + 2) | payload | FCS-16 (PPP) of the payload.
 * Payload on channel 22: 0x16, 0x00, then 32-bit LE words: 12 (header size), message id,
 * length of the rest, notification type, value. The level is message 0x04 (repeated as
 * 0x21), type 3. Charger events (types 6, 7, 8, 10 of message 0x04) are recorded raw;
 * message 0x20 (repeated as 0x08) type 3 is the signal strength in bars.
 *
 * Radio: the CAIF control command RADIO_SET on channel 0 (payload 00 08 <0 off, 1 on>; the
 * modem answers 00 28 <state>, or 00 38 <state> if it was in that state already), the
 * flight mode. Symbian keeps a break on UART3's TX line while it does not talk to the
 * modem; clearing it wakes the modem, which answers by pulling CTS (GPI_05, active low)
 * low. The other way round, the modem pulls CTS low while the break is on when it has
 * something to send, and waits for a short wake-up (break off for 20 ms): without one,
 * control replies and some notifications stay queued in the modem. RTS to the modem
 * (GPO_17) is not needed.
 *
 * Measurements: once a minute, the modem's battery object (OPA IBatteryDevice, method 7) is
 * asked for its record, on the session Symbian's BServer opened (session and stub address
 * from regprobe's scan before the handover: /media/card/other/opa.txt, the line with the
 * IID f7abbe03...; see rootfs/root/opa.sh). Request on channel 22: 0x16, 0x00, then 32-bit
 * LE words: 8, session, request id, stub, 0, method; reply: 9, status, request id, length,
 * then the result (32-bit status, the record). Known record fields (2026-10-24, compared
 * with the other getters and over time): voltage in mV, charge in %, remaining capacity in
 * mAh, the current (negative while discharging, probably 0.1 mA) and two constant values
 * (29, 43), one of them probably the temperature in degrees C; all in the status file as
 * battery_*. The percentage stands in for the level until the first notification. An
 * opa.txt from an earlier Symbian boot is not used (its stub addresses can hang the modem);
 * if the modem refuses the call anyway, polling stops.
 *
 * Power key: it hangs on the modem's power chip, and the modem reports it as a notification,
 * message 0x25, method 3: 0 = pressed, 3 = released, then the key code 0x65 (seen with the
 * modem even in its shut-down state). p1ibat reports it as KEY_POWER on a uinput device
 * ("P1i power key", for whatever runs on top), and held for 3 s it reboots, which ends up
 * in Symbian: the way out of Linux without a shell.
 *
 * Indicator LED and vibrator (both on the modem's power chip) as LED class devices, through
 * uleds: /sys/class/leds/red:indicator and green:indicator (brightness 1 = on, 0 = off; red
 * and green together light orange; the timer trigger works for slow blinking, at most one
 * modem call per LED every 0.5 s) and /sys/class/leds/vibrator (brightness 1 = vibrate until
 * 0, but at least 2 s: an earlier stop crashed the modem). For a pulse, the transient
 * trigger: echo transient > trigger; echo 1 > state; echo 300 > duration; echo 1 > activate
 * (without "state" 1 it holds the vibrator off and then switches it on). They use the same
 * opa.txt as the battery record.
 *
 *   p1ibat [-f] [-r off|on]   the daemon. -f: stay in the foreground and print every
 *                             frame; -r: switch the radio off or on at start
 *   p1ibat radio off|on       ask the running daemon to switch the radio
 */

#include <dirent.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <linux/uleds.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define UART3_PHYS	0x40080000
#define U16_RBR		0x00
#define U16_THR		0x00
#define U16_LCR		0x0c
#define U16_LSR		0x14
#define U16_LCR_BREAK	(1 << 6)
#define U16_LSR_DR	(1 << 0)
#define U16_LSR_OE	(1 << 1)
#define U16_LSR_THRE	(1 << 5)

#define GPIO_PHYS	0x40028000
#define P3_INP_STATE	0x00
#define GPI_05_CTS	(1 << 5)	/* modem ready: low */

#define CAIF_CMD_RADIO_SET	0x08
#define CAIF_RSP_BIT		0x20
#define CAIF_ERR_BIT		0x10

#define CAIF_CH_NOTIFY	22
#define MSG_BATTERY	0x04
#define MSG_BATTERY2	0x21
#define TYPE_LEVEL	3
#define MSG_KEY		0x25
#define KEY_EVENT_DOWN	0
#define KEY_EVENT_UP	3
#define KEYCODE_POWER	0x65
#define POWER_HOLD_S	3	/* held this long: reboot */
#define NTYPES		16

#define OPA_FILE	"/media/card/other/opa.txt"
#define OPA_LED_METHOD_OFF	4	/* ILedControlDevice: u8 LED */
#define OPA_LED_METHOD_BLINK	5	/* u8 LED, u32 period ms, u16 on ms (on = period: steady) */
#define OPA_VIB_METHOD_STOP	5	/* IVibratorDevice */
#define OPA_VIB_METHOD_START	6	/* u32 ms (< 0x10000), u8 */
#define LED_PERIOD_MS	1000	/* "on" = lit for the whole period; out-of-range values give */
#define LED_ON_MS	1000	/* the default flash (~150 ms every ~3.5 s) instead */
/*
 * Only values seen working: 1000 ms with 1 (Symbian's calls had 1). With 1 the motor keeps
 * going (the pattern repeats) until a stop. A stop a few seconds after the start worked;
 * the two times one came less than a second after the start (and once 65535 ms with 0) the
 * modem crashed (2026-10-25). So a stop never follows a start sooner than VIB_MIN_S.
 */
#define VIB_MS		1000
#define VIB_ARG		1
#define VIB_MIN_S	2.0
#define OPA_INVOKE	8
#define OPA_REPLY	9
#define OPA_BATTERY_RECORD	7	/* IBatteryDevice method: the whole record */
#define OPA_RECORD_LEN	63
#define OPA_POLL_S	60
#define OPA_MAX_AGE_S	1800	/* opa.txt older than this before our boot: another boot's */
#define OPA_TIMEOUT_S	30	/* no reply by the next poll (lost in an overrun): send again */

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
static int radio = -1;		/* -1 unknown, 0 off, 1 on (as confirmed by the modem) */
static volatile sig_atomic_t radio_request = -1;
static volatile sig_atomic_t quit;	/* SIGTERM/SIGINT: leave between sends, break on */
static volatile uint32_t *u3, *gpio;
static int uinput_fd = -1;
static double power_down_at;	/* 0: power key not held */

/* IBatteryDevice record (method 7): offsets of the fields */
static const struct {
	const char *name;
	int offset, size;
} record_fields[] = {
	{ "battery_mv", 12, 4 },
	{ "battery_current", 24, 4 },
	{ "battery_43", 28, 4 },	/* constant so far; temperature limit? */
	{ "battery_29", 32, 4 },	/* constant so far; temperature? */
	{ "battery_mah", 36, 4 },
	{ "battery_percent", 40, 1 },
};
#define NFIELDS (sizeof(record_fields) / sizeof(record_fields[0]))
/* The modem's objects p1ibat uses, from regprobe's scan: IID prefix, session, stub */
enum { OBJ_BATTERY, OBJ_LED, OBJ_VIBRATOR, NOBJ };
static struct {
	const char *iid;
	uint32_t session, stub;
} objs[NOBJ] = {
	{ "f7abbe03" },		/* IBatteryDevice */
	{ "99eb8af7" },		/* ILedControlDevice */
	{ "06007ab5" },		/* IVibratorDevice */
};
static uint32_t opa_reqid = 0x5b000000, cmd_reqid = 0x5d000000;

/*
 * LED class devices through uleds: the modem does the work, p1ibat passes brightness on.
 * Calls are rate limited (the modem stopped answering once after a burst of calls): at most
 * one per device every min_gap seconds, the latest state wins.
 */
static struct {
	const char *name;
	int obj, led;		/* LED number for ILedControlDevice */
	double min_gap;
	int fd, want, sent;
	double sent_at;
} leds[] = {
	{ "red:indicator", OBJ_LED, 1, 0.5 },
	{ "green:indicator", OBJ_LED, 2, 0.5 },
	{ "vibrator", OBJ_VIBRATOR, 0, VIB_MIN_S },
};
#define NLEDS (sizeof(leds) / sizeof(leds[0]))
static int opa_state;		/* 0 no opa.txt yet, 1 polling, -1 refused: stop */
static int record_valid;
static uint8_t record[OPA_RECORD_LEN];

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
	fprintf(f, "radio=%s\n", radio < 0 ? "unknown" : radio ? "on" : "off");
	for (m = 0; m < 2; m++)
		for (t = 0; t < NTYPES; t++)
			if (seen[m][t])
				fprintf(f, "%s_type%d=0x%lx\n", msgname[m], t,
					(unsigned long)(uint32_t)values[m][t]);
	for (t = 0; record_valid && t < (int)NFIELDS; t++) {
		const uint8_t *p = record + record_fields[t].offset;
		int32_t v = record_fields[t].size == 1 ? p[0] :
			    (int32_t)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24);

		fprintf(f, "%s=%ld\n", record_fields[t].name, (long)v);
	}
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

/* The power key as an input device; without uinput the hold-to-reboot still works */
static void power_key_setup(void)
{
	struct uinput_setup us;

	uinput_fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (uinput_fd < 0)
		return;
	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_HOST;
	strcpy(us.name, "P1i power key");
	if (ioctl(uinput_fd, UI_SET_EVBIT, EV_KEY) < 0 ||
	    ioctl(uinput_fd, UI_SET_KEYBIT, KEY_POWER) < 0 ||
	    ioctl(uinput_fd, UI_DEV_SETUP, &us) < 0 || ioctl(uinput_fd, UI_DEV_CREATE) < 0) {
		close(uinput_fd);
		uinput_fd = -1;
	}
}

static void power_key_report(int down)
{
	struct input_event ev[2];

	if (uinput_fd < 0)
		return;
	memset(ev, 0, sizeof(ev));
	ev[0].type = EV_KEY;
	ev[0].code = KEY_POWER;
	ev[0].value = down;
	ev[1].type = EV_SYN;
	ev[1].code = SYN_REPORT;
	/* Nothing to do if it fails: the key is only lost for whoever reads the device */
	(void)!write(uinput_fd, ev, sizeof(ev));
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
	/* Control channel: the reply to our RADIO_SET */
	if (n >= 3 && p[0] == 0 && (p[1] & 0x0f) == CAIF_CMD_RADIO_SET && (p[1] & CAIF_RSP_BIT)) {
		/* The error bit only means it was in that state already */
		radio = p[2] ? 1 : 0;
		kmsg("radio %s%s\n", p[1] & CAIF_ERR_BIT ? "already " : "",
		     radio ? "on" : "off (flight mode)");
		write_status();
		return;
	}
	/* Reply to our battery record request: 9, status, request id, length, result */
	if (n >= 2 + 16 && p[0] == CAIF_CH_NOTIFY && le32(p + 2) == OPA_REPLY &&
	    le32(p + 10) == opa_reqid) {
		opa_reqid++;	/* answered: the next poll may send */
		if (le32(p + 6) != 0 || le32(p + 14) != 4 + OPA_RECORD_LEN ||
		    n < 2 + 16 + 4 + OPA_RECORD_LEN || le32(p + 18) != 0) {
			kmsg("modem refused the battery record (status 0x%x): " OPA_FILE
			     " is from an earlier Symbian boot? Not asking again\n", le32(p + 6));
			opa_state = -1;
			return;
		}
		memcpy(record, p + 22, OPA_RECORD_LEN);
		record_valid = 1;
		/* Until the modem's own notification comes, its percentage is the level */
		if (!seen[0][TYPE_LEVEL] && record[40] <= 100)
			level = record[40];
		write_status();
		return;
	}
	if (n < 2 + 16 || p[0] != CAIF_CH_NOTIFY || le32(p + 2) != 12)
		return;
	msg = le32(p + 6);
	type = le32(p + 14);
	if (n >= 2 + 20)
		value = le32(p + 18);
	if (msg == MSG_KEY && n >= 2 + 24 && (le32(p + 22) & 0xffff) == KEYCODE_POWER) {
		if (value == KEY_EVENT_DOWN && !power_down_at) {
			power_down_at = now();
			power_key_report(1);
		} else if (value == KEY_EVENT_UP && power_down_at) {
			power_down_at = 0;
			power_key_report(0);
		}
		return;
	}
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

static void receive_pending(void)
{
	uint32_t lsr;

	while ((lsr = u3[U16_LSR / 4]) & U16_LSR_DR) {
		if (lsr & U16_LSR_OE)
			overruns++;
		handle_byte(u3[U16_RBR / 4]);
	}
}

/* Send one CAIF frame: wake the modem (clear the break, wait for CTS), send, sleep again */
static void send_payload(const uint8_t *payload, int n)
{
	uint32_t lcr = u3[U16_LCR / 4] | U16_LCR_BREAK;	/* idle: break on */
	uint16_t fcs = fcs16(payload, n);
	uint8_t frame[64];
	double t;
	int i;

	frame[0] = (n + 2) & 0xff;
	frame[1] = (n + 2) >> 8;
	memcpy(frame + 2, payload, n);
	frame[n + 2] = fcs & 0xff;
	frame[n + 3] = fcs >> 8;

	u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
	for (t = now(); gpio[P3_INP_STATE / 4] & GPI_05_CTS && now() - t < 0.5; )
		receive_pending();
	if (gpio[P3_INP_STATE / 4] & GPI_05_CTS)
		kmsg("modem did not wake up (no CTS), sending anyway\n");
	for (i = 0; i < n + 4; i++) {
		while (!(u3[U16_LSR / 4] & U16_LSR_THRE))
			receive_pending();
		u3[U16_THR / 4] = frame[i];
	}
	/* Let the last bytes leave the FIFO before the break holds the line low again */
	for (t = now(); now() - t < 0.05; )
		receive_pending();
	u3[U16_LCR / 4] = lcr;
}

/*
 * Session and stub of the objects in objs[] from regprobe's scan (the first proxy with that
 * IID: Symbian has several for some); 0 if not (yet) there, -1 if
 * the file is from an earlier Symbian boot. Its stub addresses are then meaningless, and
 * the modem dereferences them: a stale stub hung the modem (2026-10-25). The scan runs just
 * before the handover, so its file time (UTC, like ours) must be shortly before our boot.
 */
static int load_opa(void)
{
	char line[200], iid[40];
	unsigned int phys, session, stub;
	struct timespec up;
	struct stat st;
	time_t boot;
	int found = 0, i;
	FILE *f;

	if (stat(OPA_FILE, &st) < 0)
		return 0;
	clock_gettime(CLOCK_BOOTTIME, &up);
	boot = time(NULL) - up.tv_sec;
	if (st.st_mtime < boot - OPA_MAX_AGE_S || st.st_mtime > boot + 60) {
		kmsg(OPA_FILE " is not from the Symbian boot before this handover (%ld s before"
		     " it): not asking the modem (run regprobe's scan before every handover)\n",
		     (long)(boot - st.st_mtime));
		return -1;
	}
	f = fopen(OPA_FILE, "r");
	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f))
		if (sscanf(line, "%x %39s %x %x", &phys, iid, &session, &stub) == 4)
			for (i = 0; i < NOBJ; i++)
				if (!objs[i].stub && !strncmp(iid, objs[i].iid, strlen(objs[i].iid))) {
					objs[i].session = session;
					objs[i].stub = stub;
					found = 1;
				}
	fclose(f);
	return found;
}

static void put32(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

/* Ask for the battery record once a minute, once opa.txt is there (the card is mounted late) */
static void opa_poll(void)
{
	static double next, sent_at;
	static uint32_t sent_reqid = ~0u;
	uint8_t req[2 + 24] = { CAIF_CH_NOTIFY, 0 };

	if (opa_state < 0 || now() < next)
		return;
	if (opa_state == 0) {
		next = now() + 10;
		switch (load_opa()) {
		case 0:
			return;
		case -1:
			opa_state = -1;
			return;
		}
		opa_state = 1;
		kmsg("modem objects from " OPA_FILE ": battery 0x%x/0x%x, LED 0x%x/0x%x,"
		     " vibrator 0x%x/0x%x\n", objs[OBJ_BATTERY].session, objs[OBJ_BATTERY].stub,
		     objs[OBJ_LED].session, objs[OBJ_LED].stub, objs[OBJ_VIBRATOR].session,
		     objs[OBJ_VIBRATOR].stub);
	}
	if (!objs[OBJ_BATTERY].stub)
		return;
	next = now() + OPA_POLL_S;
	/* Unanswered since the last poll: the reply was lost, ask again with a new request id */
	if (sent_reqid == opa_reqid && now() - sent_at < OPA_TIMEOUT_S)
		return;
	if (sent_reqid == opa_reqid)
		opa_reqid++;
	put32(req + 2, OPA_INVOKE);
	put32(req + 6, objs[OBJ_BATTERY].session);
	put32(req + 10, opa_reqid);
	put32(req + 14, objs[OBJ_BATTERY].stub);
	put32(req + 18, 0);
	put32(req + 22, OPA_BATTERY_RECORD);
	sent_reqid = opa_reqid;
	sent_at = now();
	send_payload(req, sizeof(req));
}

/* One call on a modem object, its reply ignored (it carries another request id) */
static void opa_invoke(int obj, uint32_t method, const uint8_t *args, int nargs)
{
	uint8_t req[2 + 24 + 16] = { CAIF_CH_NOTIFY, 0 };

	put32(req + 2, OPA_INVOKE);
	put32(req + 6, objs[obj].session);
	put32(req + 10, cmd_reqid++);
	put32(req + 14, objs[obj].stub);
	put32(req + 18, 0);
	put32(req + 22, method);
	memcpy(req + 26, args, nargs);
	send_payload(req, 26 + nargs);
}

static void leds_setup(void)
{
	struct uleds_user_dev dev;
	unsigned int i;

	for (i = 0; i < NLEDS; i++) {
		leds[i].fd = open("/dev/uleds", O_RDWR | O_NONBLOCK);
		if (leds[i].fd < 0)
			continue;
		memset(&dev, 0, sizeof(dev));
		strncpy(dev.name, leds[i].name, sizeof(dev.name) - 1);
		dev.max_brightness = 1;
		if (write(leds[i].fd, &dev, sizeof(dev)) != sizeof(dev)) {
			close(leds[i].fd);
			leds[i].fd = -1;
		}
	}
}

/* New brightness from sysfs (or a trigger) -> the modem, rate limited */
static void leds_update(void)
{
	unsigned int i;
	uint8_t a[8];
	int v;

	for (i = 0; i < NLEDS; i++) {
		if (leds[i].fd < 0)
			continue;
		while (read(leds[i].fd, &v, sizeof(v)) == sizeof(v))
			leds[i].want = v > 0;
		if (opa_state != 1 || !objs[leds[i].obj].stub ||
		    now() - leds[i].sent_at < leds[i].min_gap)
			continue;
		if (leds[i].want == leds[i].sent)
			continue;
		if (leds[i].obj == OBJ_VIBRATOR) {
			if (leds[i].want) {
				put32(a, VIB_MS);
				a[4] = VIB_ARG;
				opa_invoke(OBJ_VIBRATOR, OPA_VIB_METHOD_START, a, 5);
			} else {
				opa_invoke(OBJ_VIBRATOR, OPA_VIB_METHOD_STOP, a, 0);
			}
		} else {
			a[0] = leds[i].led;
			if (leds[i].want) {
				put32(a + 1, LED_PERIOD_MS);
				a[5] = LED_ON_MS & 0xff;
				a[6] = LED_ON_MS >> 8;
				opa_invoke(OBJ_LED, OPA_LED_METHOD_BLINK, a, 7);
			} else {
				opa_invoke(OBJ_LED, OPA_LED_METHOD_OFF, a, 1);
			}
		}
		leds[i].sent = leds[i].want;
		leds[i].sent_at = now();
	}
}

static void on_quit(int sig)
{
	(void)sig;
	quit = 1;
}

static void on_signal(int sig)
{
	radio_request = sig == SIGUSR2;
}

/* "p1ibat radio off|on": signal the running daemon */
static int radio_command(const char *arg)
{
	int on = !strcmp(arg, "on");
	DIR *d = opendir("/proc");
	struct dirent *e;
	int found = 0;

	if (!on && strcmp(arg, "off")) {
		fprintf(stderr, "usage: p1ibat radio off|on\n");
		return 1;
	}
	while (d && (e = readdir(d))) {
		char path[300], comm[32] = "";
		int pid = atoi(e->d_name);
		FILE *f;

		if (pid <= 0 || pid == getpid())
			continue;
		snprintf(path, sizeof(path), "/proc/%d/comm", pid);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(comm, sizeof(comm), f) && !strcmp(comm, "p1ibat\n") &&
		    kill(pid, on ? SIGUSR2 : SIGUSR1) == 0)
			found = 1;
		fclose(f);
	}
	if (d)
		closedir(d);
	if (!found) {
		fprintf(stderr, "p1ibat is not running\n");
		return 1;
	}
	printf("asked p1ibat to switch the radio %s; see radio= in %s\n", arg, STATUS_FILE);
	return 0;
}

/* The modem asks to send (CTS low while our break is on): give it a short wake-up */
static void answer_modem(void)
{
	static double woke;
	uint32_t lcr = u3[U16_LCR / 4];
	double t;

	if (!(lcr & U16_LCR_BREAK) || gpio[P3_INP_STATE / 4] & GPI_05_CTS || now() - woke < 0.5)
		return;
	woke = now();
	u3[U16_LCR / 4] = lcr & ~U16_LCR_BREAK;
	for (t = now(); now() - t < 0.02; )
		receive_pending();
	u3[U16_LCR / 4] = lcr;
}

int main(int argc, char **argv)
{
	unsigned int warned = 0;
	double empty_since = 0, status_at = 0;
	int fd, opt, last_level = -2;
	unsigned int i;

	if (argc == 3 && !strcmp(argv[1], "radio"))
		return radio_command(argv[2]);
	while ((opt = getopt(argc, argv, "fr:")) != -1) {
		switch (opt) {
		case 'f':
			verbose = 1;
			break;
		case 'r':
			if (strcmp(optarg, "off") && strcmp(optarg, "on"))
				goto usage;
			radio_request = !strcmp(optarg, "on");
			break;
		default:
usage:
			fprintf(stderr, "usage: p1ibat [-f] [-r off|on] | p1ibat radio off|on\n");
			return 1;
		}
	}
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	u3 = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, UART3_PHYS);
	gpio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GPIO_PHYS);
	if (u3 == MAP_FAILED || gpio == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	if (!verbose && daemon(0, 0) < 0) {
		perror("daemon");
		return 1;
	}
	power_key_setup();
	leds_setup();
	/*
	 * Killed in the middle of a send, the break stayed off and the modem answered nothing
	 * any more (2026-10-25): finish the send, then leave. And repair it if found that way.
	 */
	signal(SIGTERM, on_quit);
	signal(SIGINT, on_quit);
	if (!(u3[U16_LCR / 4] & U16_LCR_BREAK)) {
		u3[U16_LCR / 4] |= U16_LCR_BREAK;
		kmsg("UART3 break was off (a tool killed while sending?): set again\n");
	}
	signal(SIGUSR1, on_signal);
	signal(SIGUSR2, on_signal);
	write_status();

	for (;;) {
		if (quit) {
			u3[U16_LCR / 4] |= U16_LCR_BREAK;
			return 0;
		}
		receive_pending();
		answer_modem();
		opa_poll();
		leds_update();

		if (radio_request >= 0) {
			uint8_t cmd[] = { 0, CAIF_CMD_RADIO_SET, radio_request };

			radio_request = -1;
			send_payload(cmd, sizeof(cmd));
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
		if (power_down_at && now() - power_down_at >= POWER_HOLD_S) {
			power_down_at = 0;
			kmsg("power key held for %d s: rebooting\n", POWER_HOLD_S);
			execl("/sbin/reboot", "reboot", (char *)NULL);
			execlp("reboot", "reboot", (char *)NULL);
			kmsg("reboot failed\n");
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
