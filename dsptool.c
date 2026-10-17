// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dsptool -- talk to the PNX4008 Teak audio DSP through its APBP host port (/dev/mem).
 *
 * Reverse-engineered from Symbian's dspextension.dll / dspbootldd.ldd (see NOTES-dsp.md in
 * the handover project). The register layout matches the Nintendo 3DS Teak DSP:
 *   APBP 0x400C0000: 0x00 PDATA, 0x04 PADR, 0x08 PCFG, 0x0C PSTS, 0x10 PSEM, 0x14 PMASK,
 *   0x18 PCLEAR, 0x1C SEM, 0x20/0x28/0x30 CMD0-2, 0x24/0x2C/0x34 REP0-2 (16-bit registers)
 *   audio config 0x400E8000: 0x64 DSPCLKCTRL
 *
 *   dsptool regs                       show the host-port and clock registers
 *   dsptool boot CODE DATA SHARED      reset the DSP, load the program/data images, start
 *                                      it and send message 11 (shared buffer address)
 *   dsptool msg TYPE P0 P1 [SUB]       send a message, wait for and print the reply
 *   dsptool rep                        print pending replies (REP0-2), if any
 *   dsptool fev SHARED H0 .. H5 [swap] message 6 with a Function Enable Vector (6 halfwords
 *                                      as in suzifev.h) at shared+0x810; "swap" stores
 *                                      each pair high halfword first
 *   dsptool sem MS                     watch the DSP->ARM semaphores (SEM) for MS ms
 *   dsptool fill SHARED AREA BYTES STEP write a sine into BYTES of shared area AREA, no
 *                                      handshake: STEP 0 = silence, 1 = 1 kHz at 48 kHz,
 *                                      2 = 2 kHz, ... (16-bit, same value in both channels)
 *   dsptool tone SHARED AREA HALF SEMIN SEMOUT MS [STEP [PMASK]]
 *                                      play a 1 kHz tone through shared area AREA (ping-pong,
 *                                      HALF bytes per half, 16-bit stereo at 48 kHz): fill a
 *                                      half whenever the DSP raises SEMIN, then set SEMOUT;
 *                                      STEP n = n kHz (default 1), PMASK default 0xffff
 *   dsptool play SHARED AREA HALF SEMIN SEMOUT FILE
 *                                      stream FILE (raw bytes: PCM, or MP3 for the DSP's
 *                                      decoder) through area AREA like tone, until its end
 *   dsptool restore SHARED FILE OFF LEN copy bytes OFF..OFF+LEN-1 of FILE (a shared buffer
 *                                      snapshot from Symbian) to the same offsets
 *   dsptool load FILE PHYS             copy FILE to physical address PHYS (SDRAM reserved
 *                                      for the DSP) and verify it
 *   dsptool modules SHARED ADDR1 ADDR2 message 12: tell the DSP where the codec module and
 *                                      the SRC filter coefficients are (block at shared+0x800:
 *                                      1, 1, ADDR1 hi, lo, ADDR2 hi, lo, as on Symbian)
 *
 * Shared buffer layout (dspextension.dll): parameter areas at +0x000/0x400/0x440/0x4C0/
 * 0x500/0x800, PCM areas 0-7 at +0x1000/0x1E00/0x2600/0x0000/0x2E00/0x3C40/0x4440/0x4C40;
 * semaphore bits per area ARM->DSP 2,3,4,0,6,7,8,9 and DSP->ARM 2,3,4,0,6,7,8,13.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define APBP_PHYS	0x400C0000
#define AUDIO_PHYS	0x400E8000

#define PDATA	0x00
#define PADR	0x04
#define PCFG	0x08
#define PSTS	0x0C
#define PSEM	0x10
#define PMASK	0x14
#define SEM	0x1C
#define CMD(n)	(0x20 + 8 * (n))
#define REP(n)	(0x24 + 8 * (n))

#define PCFG_RESET	(1 << 0)
#define PCFG_AUTOINC	(1 << 1)
#define PCFG_REP0_IE	(1 << 9)
#define PCFG_MEM_SHIFT	12
#define MEM_DATA	0x0
#define MEM_PROGRAM	0x5

#define PSTS_WR_BUSY	(1 << 1)
#define PSTS_REP0	(1 << 10)
#define PSTS_CMD0	(1 << 13)

#define PCLEAR	0x18

#define SHARED_SIZE	0x6000	/* dspextension's DSharedIoBuffer */

static const uint32_t area_off[8] = { 0x1000, 0x1E00, 0x2600, 0x0000, 0x2E00, 0x3C40, 0x4440,
				      0x4C40 };

#define DSPCLKCTRL	0x64

/* Data memory words not written by "boot": the DSP's own I/O registers (as on the 3DS). */
#define DATA_MMIO_FIRST	0x8000
#define DATA_MMIO_LAST	0x87FF

static volatile uint8_t *apbp, *audio;

static uint16_t rd(unsigned int off)
{
	return *(volatile uint16_t *)(apbp + off);
}

static void wr(unsigned int off, uint16_t v)
{
	*(volatile uint16_t *)(apbp + off) = v;
}

static uint32_t clk_rd(void)
{
	return *(volatile uint32_t *)(audio + DSPCLKCTRL);
}

static void clk_wr(uint32_t v)
{
	*(volatile uint32_t *)(audio + DSPCLKCTRL) = v;
}

static void delay_us(unsigned int us)
{
	struct timespec ts = { 0, us * 1000L };

	nanosleep(&ts, NULL);
}

static void *map(int fd, off_t phys)
{
	void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, phys);

	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	return p;
}

static void regs(void)
{
	printf("PCFG %04x PSTS %04x PSEM %04x PMASK %04x SEM %04x\n",
	       rd(PCFG), rd(PSTS), rd(PSEM), rd(PMASK), rd(SEM));
	printf("CMD0 %04x CMD1 %04x CMD2 %04x  REP: not read (reading clears them)\n",
	       rd(CMD(0)), rd(CMD(1)), rd(CMD(2)));
	printf("DSPPLLCTRL %08x DSPCLKCTRL %08x AUDIOCLKCTRL %08x AUDIOPLLCTRL %08x\n",
	       *(volatile uint32_t *)(audio + 0x60), clk_rd(),
	       *(volatile uint32_t *)(audio + 0x68), *(volatile uint32_t *)(audio + 0x6C));
}

/* dspextension export #16: power the DSP up and hold it in reset. */
static void power_up(void)
{
	uint16_t cfg = rd(PCFG);

	clk_wr(clk_rd() & ~0x40);
	clk_wr(clk_rd() | 0x18);
	delay_us(1);
	clk_wr(clk_rd() | 0x1020);
	clk_wr(clk_rd() | 0x4000);
	wr(PCFG, rd(PCFG) | cfg | PCFG_RESET);
	delay_us(1);
}

/* Exports #11 (program) and #8 (data): write words through PDATA, DSP held in reset. */
static void download(const uint16_t *w, size_t n, unsigned int mem, uint16_t addr)
{
	clk_wr(clk_rd() & ~0x1020);
	delay_us(1);
	clk_wr(clk_rd() | 0x1020);
	wr(PCFG, rd(PCFG) | PCFG_RESET);
	delay_us(1);
	wr(PCFG, rd(PCFG) & ~0xF000);
	wr(PCFG, rd(PCFG) | (mem << PCFG_MEM_SHIFT) | PCFG_AUTOINC);
	wr(PADR, addr);
	while (n--)
		wr(PDATA, *w++);
	while (rd(PSTS) & PSTS_WR_BUSY)
		;
}

/* Export #15: release reset. */
static void start(void)
{
	clk_wr(clk_rd() & ~0x1020);
	delay_us(1);
	clk_wr(clk_rd() | 0x2000);
	clk_wr(clk_rd() | 0x1020);
	wr(PCFG, rd(PCFG) & ~PCFG_RESET);
}

static uint16_t *load_file(const char *path, size_t *words)
{
	FILE *f = fopen(path, "rb");
	uint16_t *buf;
	long len;

	if (!f) {
		perror(path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	len = ftell(f);
	rewind(f);
	buf = malloc(len + 1);
	if (!buf || fread(buf, 1, len, f) != (size_t)len) {
		fprintf(stderr, "%s: read failed\n", path);
		exit(1);
	}
	fclose(f);
	*words = len / 2;
	return buf;
}

/* Read and print whatever replies are pending; returns REP0 or -1 if none. */
static int rep(const char *what)
{
	uint16_t sts = rd(PSTS), r0, r1, r2;

	if (!(sts & (PSTS_REP0 | PSTS_REP0 << 1 | PSTS_REP0 << 2))) {
		printf("%s: no reply pending (PSTS %04x)\n", what, sts);
		return -1;
	}
	r2 = rd(REP(2));
	r1 = rd(REP(1));
	r0 = rd(REP(0));
	printf("%s: PSTS %04x REP0 %04x REP1 %04x REP2 %04x\n", what, sts, r0, r1, r2);
	return r0;
}

/* Send a message the way dspextension does and wait for REP0 (polling, no interrupt). */
static int msg(unsigned int type, unsigned int sub, uint16_t p0, uint16_t p1)
{
	int i;
	uint16_t r0, r1, r2;

	/* Replies that arrived unasked (e.g. the start-up notification) would be taken for ours. */
	rep("stale");
	for (i = 0; i < 1000 && (rd(PSTS) & PSTS_CMD0); i++)
		delay_us(1000);
	if (rd(PSTS) & PSTS_CMD0)
		fprintf(stderr, "warning: CMD0 still unread by the DSP\n");

	wr(PCFG, rd(PCFG) | PCFG_REP0_IE);
	wr(CMD(2), p1);
	wr(CMD(1), p0);
	wr(CMD(0), (type & 0xFF) | (sub & 0xF) << 12);

	for (i = 0; i < 2000 && !(rd(PSTS) & PSTS_REP0); i++)
		delay_us(1000);
	if (!(rd(PSTS) & PSTS_REP0)) {
		printf("msg %u: no reply within 2 s (PSTS %04x)\n", type, rd(PSTS));
		return -1;
	}
	r2 = rd(REP(2));
	r1 = rd(REP(1));
	r0 = rd(REP(0));
	printf("msg %u (%04x %04x): REP0 %04x REP1 %04x REP2 %04x -> %s, status %u\n",
	       type, p0, p1, r0, r1, r2, (r0 & 0xFF) == type ? "ok" : "type mismatch",
	       (r0 >> 8) & 0xF);
	return (r0 & 0xFF) == type ? 0 : -1;
}

static void boot(const char *code_path, const char *data_path, uint32_t shared, int fd)
{
	size_t nc, nd;
	int i;
	uint16_t *code = load_file(code_path, &nc);
	uint16_t *data = load_file(data_path, &nd);

	/*
	 * Zero the shared buffer so whatever the DSP writes there stands out. Only its 0x6000
	 * bytes: Symbian puts it at the start of the internal SRAM (0x08000000), whose rest is
	 * used by others (clearing all 64 KB turned the display off).
	 */
	{
		void *sh = mmap(NULL, SHARED_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, shared);

		if (sh == MAP_FAILED) {
			perror("mmap shared");
			exit(1);
		}
		memset(sh, 0, SHARED_SIZE);
		munmap(sh, SHARED_SIZE);
	}
	printf("before:\n");
	regs();
	power_up();
	download(code, nc, MEM_PROGRAM, 0);
	printf("program: %zu words at 0\n", nc);
	if (nd > DATA_MMIO_FIRST) {
		download(data, DATA_MMIO_FIRST, MEM_DATA, 0);
		if (nd > DATA_MMIO_LAST + 1)
			download(data + DATA_MMIO_LAST + 1, nd - DATA_MMIO_LAST - 1, MEM_DATA,
				 DATA_MMIO_LAST + 1);
	} else {
		download(data, nd, MEM_DATA, 0);
	}
	printf("data: %zu words at 0 (0x%x-0x%x skipped)\n", nd, DATA_MMIO_FIRST, DATA_MMIO_LAST);
	start();
	for (i = 0; i < 1000 && !(rd(PSTS) & PSTS_REP0); i++)
		delay_us(1000);
	printf("started (%d ms):\n", i);
	regs();
	rep("start-up notification");
	msg(11, 0, shared >> 16, shared & 0xFFFF);
}

static volatile uint16_t *map_shared(int fd, uint32_t shared)
{
	void *p = mmap(NULL, SHARED_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, shared);

	if (p == MAP_FAILED) {
		perror("mmap shared");
		exit(1);
	}
	return p;
}

/* dspextension #12: set ARM->DSP semaphore bits, with the DSP clock request held (bit 9). */
static void psem(uint16_t bits)
{
	uint32_t clk = clk_rd();

	clk_wr(clk | 0x200);
	(void)clk_rd();
	(void)clk_rd();
	(void)clk_rd();
	wr(PSEM, rd(PSEM) | bits);
	clk_wr(clk);
}

static long now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void sem_watch(int ms)
{
	long end = now_ms() + ms;
	uint16_t seen = 0, last = 0xffff;
	unsigned int n = 0;

	wr(PMASK, 0xffff);	/* no interrupts: polled */
	while (now_ms() < end) {
		uint16_t s = rd(SEM);

		if (s != last)
			printf("%6ld ms: SEM %04x PSTS %04x\n", ms - (end - now_ms()), s, rd(PSTS));
		last = s;
		if (s) {
			seen |= s;
			n++;
			wr(PCLEAR, s);
		}
		delay_us(200);
	}
	printf("bits seen: %04x (%u acks)\n", seen, n);
}

/* Message 6: the Function Enable Vector, 6 halfwords at shared+0x810. */
static int fev(volatile uint16_t *sh, uint16_t *h, int swap)
{
	int i;

	for (i = 0; i < 6; i += 2) {
		sh[0x810 / 2 + i] = swap ? h[i + 1] : h[i];
		sh[0x810 / 2 + i + 1] = swap ? h[i] : h[i + 1];
	}
	return msg(6, 0, 6, 0x810);
}

/* Message 12: the DSP's module buffers in SDRAM, 6 halfwords at shared+0x800. */
static int modules(volatile uint16_t *sh, uint32_t a1, uint32_t a2)
{
	sh[0x800 / 2 + 0] = 1;
	sh[0x800 / 2 + 1] = 1;
	sh[0x800 / 2 + 2] = a1 >> 16;
	sh[0x800 / 2 + 3] = a1 & 0xFFFF;
	sh[0x800 / 2 + 4] = a2 >> 16;
	sh[0x800 / 2 + 5] = a2 & 0xFFFF;
	return msg(12, 0, 6, 0x800);
}

/* Copy a file to physical memory (not mapped by the kernel: a no-map reservation). */
static int load_phys(int fd, const char *path, uint32_t phys)
{
	size_t words, len, maplen, i, bad = 0;
	uint32_t base = phys & ~0xFFFu;
	const uint8_t *src = (const uint8_t *)load_file(path, &words);
	volatile uint8_t *map_p, *p;

	len = words * 2;	/* both module files have an even size */
	maplen = (phys - base + len + 0xFFF) & ~0xFFFu;
	map_p = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
	if (map_p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	p = map_p + (phys - base);
	for (i = 0; i < len; i++)
		p[i] = src[i];
	for (i = 0; i < len; i++)
		bad += p[i] != src[i];
	printf("%s: %zu bytes at 0x%08x-0x%08zx, %zu differ on read-back\n", path, len, phys,
	       phys + len - 1, bad);
	munmap((void *)map_p, maplen);
	return bad ? 1 : 0;
}

static const int16_t sine48[48] = {
	0, 1305, 2588, 3827, 5000, 6088, 7071, 7934, 8660, 9239, 9659, 9914,
	10000, 9914, 9659, 9239, 8660, 7934, 7071, 6088, 5000, 3827, 2588, 1305,
	0, -1305, -2588, -3827, -5000, -6088, -7071, -7934, -8660, -9239, -9659, -9914,
	-10000, -9914, -9659, -9239, -8660, -7934, -7071, -6088, -5000, -3827, -2588, -1305 };

static void fill(volatile uint16_t *sh, int area, unsigned int bytes, unsigned int step)
{
	volatile uint16_t *base = sh + area_off[area] / 2;
	unsigned int i, phase = 0;

	for (i = 0; i < bytes / 4; i++, phase = (phase + step) % 48)
		base[2 * i] = base[2 * i + 1] = step ? sine48[phase] : 0;
}

static void tone(volatile uint16_t *sh, int area, unsigned int half, int semin, int semout,
		 int ms, unsigned int step, uint16_t pmask)
{
	volatile uint16_t *base = sh + area_off[area] / 2;
	unsigned int frames = half / 4, i, cur = 0, phase = 0, fills = 0;
	uint16_t others = 0;
	long end = now_ms() + ms;
	static const int16_t sine[48] = {
		0, 1305, 2588, 3827, 5000, 6088, 7071, 7934, 8660, 9239, 9659, 9914,
		10000, 9914, 9659, 9239, 8660, 7934, 7071, 6088, 5000, 3827, 2588, 1305,
		0, -1305, -2588, -3827, -5000, -6088, -7071, -7934, -8660, -9239, -9659, -9914,
		-10000, -9914, -9659, -9239, -8660, -7934, -7071, -6088, -5000, -3827, -2588, -1305 };

	wr(PMASK, pmask);
	for (cur = 0; cur < 2; cur++)
		for (i = 0; i < frames; i++, phase = (phase + step) % 48)
			base[cur * half / 2 + 2 * i] = base[cur * half / 2 + 2 * i + 1] = sine[phase];
	psem(1 << semout);
	cur = 0;
	while (now_ms() < end) {
		uint16_t s = rd(SEM);

		/* Other bits are acknowledged too, so they cannot hold the DSP up. */
		if (s & ~(1 << semin)) {
			others |= s & ~(1 << semin);
			wr(PCLEAR, s & ~(1 << semin));
		}
		if (!(s & (1 << semin))) {
			delay_us(100);
			continue;
		}
		wr(PCLEAR, 1 << semin);
		for (i = 0; i < frames; i++, phase = (phase + step) % 48)
			base[cur * half / 2 + 2 * i] = base[cur * half / 2 + 2 * i + 1] = sine[phase];
		psem(1 << semout);
		cur ^= 1;
		fills++;
	}
	printf("tone: %u half buffers filled in %d ms (expected about %u at 48 kHz), PSEM %04x "
	       "SEM %04x, other bits acknowledged %04x\n", fills, ms, ms * 48 / frames, rd(PSEM),
	       rd(SEM), others);
	wr(PMASK, 0xffff);
}

/* Copy the next HALF bytes of the file into half CUR (zeros after its end). */
static int play_fill(volatile uint16_t *half, FILE *f, unsigned int bytes)
{
	uint16_t buf[2048];
	size_t n = fread(buf, 1, bytes, f), i;

	memset((uint8_t *)buf + n, 0, bytes - n);
	for (i = 0; i < bytes / 2; i++)
		half[i] = buf[i];
	return n > 0;
}

static int play(volatile uint16_t *sh, int area, unsigned int half, int semin, int semout,
		const char *path)
{
	volatile uint16_t *base = sh + area_off[area] / 2;
	FILE *f = fopen(path, "rb");
	unsigned int cur, fills = 0, left = 2;
	uint16_t others = 0;
	long start = now_ms(), last = start;

	if (!f || half > 4096 || half & 1) {
		fprintf(stderr, "play: cannot open %s or bad half size\n", path);
		return 1;
	}
	wr(PMASK, 0xbff8);
	play_fill(base, f, half);
	play_fill(base + half / 2, f, half);
	psem(1 << semout);
	cur = 0;
	/* Until the file is done and both halves played, or 3 s without a request. */
	while (left && now_ms() - last < 3000) {
		uint16_t s = rd(SEM);

		if (s & ~(1 << semin)) {
			others |= s & ~(1 << semin);
			wr(PCLEAR, s & ~(1 << semin));
		}
		if (!(s & (1 << semin))) {
			delay_us(100);
			continue;
		}
		wr(PCLEAR, 1 << semin);
		last = now_ms();
		if (!play_fill(base + cur * half / 2, f, half))
			left--;
		psem(1 << semout);
		cur ^= 1;
		fills++;
	}
	printf("play: %u halves of %u bytes in %ld ms (%ld bytes/s), %s, other bits %04x\n",
	       fills, half, now_ms() - start, fills * half * 1000L / (now_ms() - start + 1),
	       left ? "stalled (3 s without a request)" : "file done", others);
	fclose(f);
	wr(PMASK, 0xffff);
	return 0;
}

static int restore(volatile uint16_t *sh, const char *path, unsigned int off, unsigned int len)
{
	size_t words, i;
	uint16_t *buf = load_file(path, &words);

	if ((off | len) & 1 || off + len > words * 2 || off + len > SHARED_SIZE) {
		fprintf(stderr, "restore: bad range\n");
		return 1;
	}
	for (i = off / 2; i < (off + len) / 2; i++)
		sh[i] = buf[i];
	printf("restored 0x%x-0x%x from %s\n", off, off + len - 1, path);
	return 0;
}

int main(int argc, char **argv)
{
	int fd;

	if (argc < 2) {
		fprintf(stderr, "usage: dsptool regs | rep | boot CODE DATA SHARED_PHYS | "
			"msg TYPE P0 P1 [SUB] | fev SHARED H0..H5 [swap] | sem MS |\n"
			"       tone SHARED AREA HALF SEMIN SEMOUT MS [STEP [PMASK]] | load FILE PHYS |\n"
			"       modules SHARED ADDR1 ADDR2 | restore SHARED FILE OFF LEN |\n"
			"       play SHARED AREA HALF SEMIN SEMOUT FILE\n");
		return 1;
	}
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	apbp = map(fd, APBP_PHYS);
	audio = map(fd, AUDIO_PHYS);

	if (!strcmp(argv[1], "regs")) {
		regs();
	} else if (!strcmp(argv[1], "rep")) {
		rep("pending");
	} else if (!strcmp(argv[1], "boot") && argc == 5) {
		boot(argv[2], argv[3], strtoul(argv[4], NULL, 0), fd);
	} else if (!strcmp(argv[1], "fev") && argc >= 9) {
		uint16_t h[6];
		int i;

		for (i = 0; i < 6; i++)
			h[i] = strtoul(argv[3 + i], NULL, 0);
		return fev(map_shared(fd, strtoul(argv[2], NULL, 0)), h,
			   argc > 9 && !strcmp(argv[9], "swap")) ? 1 : 0;
	} else if (!strcmp(argv[1], "sem") && argc == 3) {
		sem_watch(atoi(argv[2]));
	} else if (!strcmp(argv[1], "fill") && argc == 6) {
		fill(map_shared(fd, strtoul(argv[2], NULL, 0)), atoi(argv[3]),
		     strtoul(argv[4], NULL, 0), atoi(argv[5]));
	} else if (!strcmp(argv[1], "tone") && argc >= 8) {
		tone(map_shared(fd, strtoul(argv[2], NULL, 0)), atoi(argv[3]),
		     strtoul(argv[4], NULL, 0), atoi(argv[5]), atoi(argv[6]), atoi(argv[7]),
		     argc > 8 ? atoi(argv[8]) : 1, argc > 9 ? strtoul(argv[9], NULL, 0) : 0xffff);
	} else if (!strcmp(argv[1], "play") && argc == 8) {
		return play(map_shared(fd, strtoul(argv[2], NULL, 0)), atoi(argv[3]),
			    strtoul(argv[4], NULL, 0), atoi(argv[5]), atoi(argv[6]), argv[7]);
	} else if (!strcmp(argv[1], "restore") && argc == 6) {
		return restore(map_shared(fd, strtoul(argv[2], NULL, 0)), argv[3],
			       strtoul(argv[4], NULL, 0), strtoul(argv[5], NULL, 0));
	} else if (!strcmp(argv[1], "load") && argc == 4) {
		return load_phys(fd, argv[2], strtoul(argv[3], NULL, 0));
	} else if (!strcmp(argv[1], "modules") && argc == 5) {
		return modules(map_shared(fd, strtoul(argv[2], NULL, 0)),
			       strtoul(argv[3], NULL, 0), strtoul(argv[4], NULL, 0)) ? 1 : 0;
	} else if (!strcmp(argv[1], "msg") && argc >= 5) {
		return msg(strtoul(argv[2], NULL, 0), argc > 5 ? strtoul(argv[5], NULL, 0) : 0,
			   strtoul(argv[3], NULL, 0), strtoul(argv[4], NULL, 0)) ? 1 : 0;
	} else {
		fprintf(stderr, "bad arguments\n");
		return 1;
	}
	return 0;
}
