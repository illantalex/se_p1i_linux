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

	/* Zero the shared buffer so whatever the DSP writes there stands out. */
	{
		void *sh = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, shared);

		if (sh == MAP_FAILED) {
			perror("mmap shared");
			exit(1);
		}
		memset(sh, 0, 0x10000);
		munmap(sh, 0x10000);
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

int main(int argc, char **argv)
{
	int fd;

	if (argc < 2) {
		fprintf(stderr, "usage: dsptool regs | rep | boot CODE DATA SHARED_PHYS | "
			"msg TYPE P0 P1 [SUB]\n");
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
	} else if (!strcmp(argv[1], "msg") && argc >= 5) {
		return msg(strtoul(argv[2], NULL, 0), argc > 5 ? strtoul(argv[5], NULL, 0) : 0,
			   strtoul(argv[3], NULL, 0), strtoul(argv[4], NULL, 0)) ? 1 : 0;
	} else {
		fprintf(stderr, "bad arguments\n");
		return 1;
	}
	return 0;
}
