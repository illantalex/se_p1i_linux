/*
 * uartspy.c -- watch the modem link UARTs without configuring them: poll the receive FIFOs
 * of HS UART1/2/7 (0x40014000/18000/1C000) and UART3 (0x40080000, 16550) through /dev/mem
 * and print every byte received, with a timestamp. Nothing is written to any UART register;
 * reading the FIFOs takes the bytes out (Symbian is gone, nobody else reads them).
 *
 *   uartspy [SECONDS]     (default 60)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define HSU_FIFO	0x00
#define HSU_LEVEL	0x04
#define HSU_RX_EMPTY	(1 << 8)
#define U16_RBR		0x00
#define U16_LSR		0x14
#define U16_LSR_DR	(1 << 0)

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static volatile uint32_t *map(int fd, off_t phys)
{
	void *p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, phys);

	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	return p;
}

int main(int argc, char **argv)
{
	static const struct { const char *name; off_t phys; int hs; } ports[] = {
		{ "hsu1", 0x40014000, 1 },
		{ "hsu2", 0x40018000, 1 },
		{ "hsu7", 0x4001C000, 1 },
		{ "uart3", 0x40080000, 0 },
	};
	volatile uint32_t *r[4];
	unsigned long count[4] = { 0 };
	int last = -1, col = 0;
	double t0, end;
	int fd, i;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	for (i = 0; i < 4; i++)
		r[i] = map(fd, ports[i].phys);

	t0 = now();
	end = t0 + (argc > 1 ? atof(argv[1]) : 60);
	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("watching hsu1 hsu2 hsu7 uart3 for %.0f s\n", end - t0);
	while (now() < end) {
		for (i = 0; i < 4; i++) {
			for (;;) {
				uint32_t v;

				if (ports[i].hs) {
					v = r[i][HSU_FIFO / 4];
					if (v & HSU_RX_EMPTY)
						break;
				} else {
					if (!(r[i][U16_LSR / 4] & U16_LSR_DR))
						break;
					v = r[i][U16_RBR / 4];
				}
				if (i != last || col == 16) {
					printf("%s%8.3f %-5s", last >= 0 ? "\n" : "", now() - t0,
					       ports[i].name);
					last = i;
					col = 0;
				}
				/* Upper bits of an HS UART FIFO word: break (10) and error (9) flags */
				printf(" %02x%s", v & 0xff, v & 0x600 ? "!" : "");
				col++;
				count[i]++;
			}
		}
		usleep(200);
	}
	printf("\nbytes: hsu1 %lu hsu2 %lu hsu7 %lu uart3 %lu\n",
	       count[0], count[1], count[2], count[3]);
	return 0;
}
