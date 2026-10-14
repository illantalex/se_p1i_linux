// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Multi-call wrapper for the libgpiod tools, BusyBox-style: one statically linked binary
 * (one copy of glibc) instead of five ~660 KB ones, which would not fit the 4 MB payload.
 * build.sh renames each tool's main() to <tool>_main with objcopy and links them with
 * this; /usr/bin/gpioset etc. are symlinks to it. memdump.c and evdump.c ride along
 * the same way.
 */

#include <stdio.h>
#include <string.h>

int gpiodetect_main(int argc, char **argv);
int gpioinfo_main(int argc, char **argv);
int gpioget_main(int argc, char **argv);
int gpioset_main(int argc, char **argv);
int gpiomon_main(int argc, char **argv);
int memdump_main(int argc, char **argv);
int evdump_main(int argc, char **argv);

static const struct {
	const char *name;
	int (*main)(int argc, char **argv);
} tools[] = {
	{ "gpiodetect", gpiodetect_main },
	{ "gpioinfo", gpioinfo_main },
	{ "gpioget", gpioget_main },
	{ "gpioset", gpioset_main },
	{ "gpiomon", gpiomon_main },
	{ "memdump", memdump_main },
	{ "evdump", evdump_main },
};

int main(int argc, char **argv)
{
	const char *name = strrchr(argv[0], '/');
	unsigned int i;

	name = name ? name + 1 : argv[0];
	for (i = 0; i < sizeof(tools) / sizeof(tools[0]); i++)
		if (!strcmp(name, tools[i].name))
			return tools[i].main(argc, argv);

	fprintf(stderr, "%s: call as one of:", name);
	for (i = 0; i < sizeof(tools) / sizeof(tools[0]); i++)
		fprintf(stderr, " %s", tools[i].name);
	fprintf(stderr, "\n");
	return 1;
}
