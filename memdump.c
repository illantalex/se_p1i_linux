// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * memdump -- dump or summarise physical address ranges through /dev/mem, one 4 KB page at
 * a time, surviving pages whose reads fault (unmapped holes give external aborts, which
 * reach a user process as SIGBUS/SIGSEGV).
 *
 *   memdump ADDR LEN      hex dump, 4 words per line, repeated lines collapsed to "*"
 *   memdump -s ADDR LEN   one line per page: hash, non-zero word count, first word
 *
 * The summary is for comparing two boots (e.g. Symbian handover with and without the FM
 * radio playing): pages whose hash differs are worth a full dump. Reads are 32-bit only.
 * Reading can have side effects (FIFOs, clear-on-read status), so avoid the console UART
 * (0x40098000) and blocks in use.
 */

#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE		4096u
#define WORDS		(PAGE / 4)

static sigjmp_buf fault_jmp;

static void fault_handler(int sig)
{
	siglongjmp(fault_jmp, sig);
}

/* Read one page into buf; returns 0, or the signal number if a read faulted. */
static int read_page(int fd, uint32_t addr, uint32_t *buf)
{
	volatile uint32_t *p;
	void *map;
	int sig;

	map = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, fd, addr);
	if (map == MAP_FAILED)
		return -1;
	p = map;

	sig = sigsetjmp(fault_jmp, 1);
	if (!sig) {
		for (unsigned int i = 0; i < WORDS; i++)
			buf[i] = p[i];
	}
	munmap(map, PAGE);
	return sig;
}

int main(int argc, char **argv)
{
	static uint32_t buf[WORDS];
	struct sigaction sa;
	uint32_t addr, end, prev[4];
	int summary = 0, have_prev = 0, starred = 0, fd;

	if (argc > 1 && !strcmp(argv[1], "-s")) {
		summary = 1;
		argv++;
		argc--;
	}
	if (argc != 3) {
		fprintf(stderr, "usage: memdump [-s] ADDR LEN\n");
		return 1;
	}
	addr = strtoul(argv[1], NULL, 0) & ~(PAGE - 1);
	end = strtoul(argv[1], NULL, 0) + strtoul(argv[2], NULL, 0);

	fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = fault_handler;
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);

	for (; addr < end; addr += PAGE) {
		int ret = read_page(fd, addr, buf);

		if (ret) {
			printf("%08x: %s\n", addr, ret < 0 ? "MAP FAILED" :
			       ret == SIGBUS ? "FAULT (SIGBUS)" : "FAULT (SIGSEGV)");
			have_prev = 0;
			fflush(stdout);
			if (addr + PAGE < addr)
				break;
			continue;
		}

		if (summary) {
			uint32_t hash = 2166136261u;
			unsigned int nz = 0;

			for (unsigned int i = 0; i < WORDS; i++) {
				hash = (hash ^ buf[i]) * 16777619u;
				nz += buf[i] != 0;
			}
			printf("%08x: hash %08x nz %4u first %08x\n", addr, hash, nz, buf[0]);
		} else {
			for (unsigned int i = 0; i < WORDS; i += 4) {
				if (have_prev && !memcmp(prev, &buf[i], sizeof(prev))) {
					if (!starred)
						printf("*\n");
					starred = 1;
					continue;
				}
				printf("%08x: %08x %08x %08x %08x\n", addr + i * 4,
				       buf[i], buf[i + 1], buf[i + 2], buf[i + 3]);
				memcpy(prev, &buf[i], sizeof(prev));
				have_prev = 1;
				starred = 0;
			}
		}
		fflush(stdout);
		if (addr + PAGE < addr)
			break;
	}
	return 0;
}
