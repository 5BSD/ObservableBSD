/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace — process tracing via FreeBSD Hardware Trace (HWT).
 *
 * Entry point, usage, subcommand dispatch, and shared helpers.
 */

#include <sys/types.h>
#include <sys/sysctl.h>

#include <ctype.h>
#include <err.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	BSDTRACE_VERSION	"0.1.0"

static void
usage(void)
{

	fprintf(stderr,
	    "usage: bsdtrace <command> [options]\n"
	    "\n"
	    "Commands:\n"
	    "  list              Show HWT framework and backend status\n"
	    "  exec [opts] -- cmd  Run a command under hardware trace\n"
	    "  trace [opts] pid  Attach to a running process\n"
	    "  decode [opts] .pt Decode a saved trace offline\n"
	    "\n"
	    "Common options:\n"
	    "  -f format   Output: text, json, profile, or tree\n"
	    "  -d seconds  Trace duration (-t also accepted)\n"
	    "  -s size     Buffer size, e.g. 8m, 64m (default: 64m)\n"
	    "  -o file     Output .pt file path\n"
	    "  -r range    IP filter: 0xstart:0xend or function_name\n"
	    "  -T tid      Thread index (default: 0)\n"
	    "  -h          Per-command help\n"
	    "\n"
	    "Requires root and kernel modules: kldload hwt && kldload pt\n"
	    );
	exit(1);
}

/* ------------------------------------------------------------------ */
/* Shared helpers                                                      */
/* ------------------------------------------------------------------ */

/*
 * Parse a human-readable size string: "4m" → 4194304, "16k" → 16384.
 * Returns bytes.  Defaults to 4 if the numeric part is unparseable.
 */
size_t
parse_size(const char *s)
{
	char *end;
	long val;
	size_t mult;

	val = strtol(s, &end, 10);
	if (val <= 0)
		val = 4;

	switch (tolower((unsigned char)*end)) {
	case 'g':
		mult = 1024UL * 1024 * 1024;
		break;
	case 'm':
		mult = 1024UL * 1024;
		break;
	case 'k':
		mult = 1024UL;
		break;
	default:
		mult = 1;
		break;
	}

	return ((size_t)val * mult);
}

/*
 * Look up the executable name for a PID via sysctl.
 * Returns basename pointer into buf on success, NULL on failure.
 */
const char *
process_name(pid_t pid, char *buf, size_t bufsz)
{
	char *p;

	if (process_exe_fullpath(pid, buf, bufsz) != 0)
		return (NULL);

	p = strrchr(buf, '/');
	if (p != NULL)
		return (p + 1);
	return (buf);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int
main(int argc, char **argv)
{

	if (argc < 2)
		usage();

	if (strcmp(argv[1], "list") == 0)
		return (cmd_list(argc - 1, argv + 1));
	if (strcmp(argv[1], "exec") == 0)
		return (cmd_exec(argc - 1, argv + 1));
	if (strcmp(argv[1], "trace") == 0)
		return (cmd_trace(argc - 1, argv + 1));
	if (strcmp(argv[1], "decode") == 0)
		return (cmd_decode(argc - 1, argv + 1));

	if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0) {
		printf("bsdtrace %s\n", BSDTRACE_VERSION);
		return (0);
	}

	fprintf(stderr, "bsdtrace: unknown command '%s'\n", argv[1]);
	usage();
	/* NOTREACHED */
	return (1);
}
