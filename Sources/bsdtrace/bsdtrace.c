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
	    "usage: bsdtrace list    [-f text|json]\n"
	    "       bsdtrace exec    [-f text|json] [-b backend] [-s bufsize]\n"
	    "                       [-t timeout] [-m maxrec] [-o ptfile] [-np]\n"
	    "                       -- cmd [args...]\n"
	    "       bsdtrace trace   [-f text|json] [-b backend] [-s bufsize]\n"
	    "                       [-d duration] [-m maxrec] [-o ptfile] [-np]\n"
	    "                       pid\n"
	    "\n"
	    "Options:\n"
	    "  -f format    Output format: text (default) or json\n"
	    "  -b backend   HWT backend name (default: auto-detect)\n"
	    "  -s bufsize   Trace buffer size, e.g. 4m, 16m (default: 4m)\n"
	    "  -t timeout   Maximum trace duration in seconds (exec, default: 30)\n"
	    "  -d duration  Trace duration in seconds (trace, 0 = until Ctrl-C)\n"
	    "  -m maxrec    Stop after N records (0 = unlimited)\n"
	    "  -o ptfile    Output path for raw PT data (default: bsdtrace-<pid>.pt)\n"
	    "  -T tid       Thread index to trace (default: 0)\n"
	    "  -n           Dry run: validate setup without tracing\n"
	    "  -p           Pause target on mmap/exec events\n"
	    "\n"
	    "Requires root and two kernel modules:\n"
	    "  sudo kldload hwt && sudo kldload pt\n"
	    );
	exit(1);
}

/* ------------------------------------------------------------------ */
/* Trace state — shared accumulator for polling loops                  */
/* ------------------------------------------------------------------ */

void
trace_state_init(struct trace_state *ts, struct meta_writer *meta)
{

	memset(ts, 0, sizeof(*ts));
	ts->meta = meta;
	ts->last_buf_page = -1;
	ts->max_buf_page = -1;
}

void
trace_state_process(struct trace_state *ts,
    const struct bsdtrace_record *rec)
{

	meta_writer_record(ts->meta, rec);

	if (rec->type == HWT_RECORD_BUFFER) {
		if (ts->max_buf_page >= 0 &&
		    rec->curpage < ts->max_buf_page)
			ts->buf_wrapped = true;
		if (rec->curpage > ts->max_buf_page)
			ts->max_buf_page = rec->curpage;
		ts->last_buf_page = rec->curpage;
		ts->last_buf_offset = rec->offset;
	}

	if ((rec->type == HWT_RECORD_EXECUTABLE ||
	    rec->type == HWT_RECORD_MMAP) &&
	    rec->fullpath[0] != '\0') {
		if (ts->nsections >= ts->sections_cap) {
			ts->sections_cap = ts->sections_cap == 0 ?
			    32 : ts->sections_cap * 2;
			ts->sections = reallocf(ts->sections,
			    ts->sections_cap * sizeof(*ts->sections));
		}
		if (ts->sections != NULL) {
			strlcpy(ts->sections[ts->nsections].path,
			    rec->fullpath,
			    sizeof(ts->sections[ts->nsections].path));
			ts->sections[ts->nsections].load_addr = rec->addr;
			ts->sections[ts->nsections].base_addr = rec->baseaddr;
			ts->sections[ts->nsections].type = rec->type;
			ts->nsections++;
		}
	}
}

void
trace_state_free(struct trace_state *ts)
{

	free(ts->sections);
	ts->sections = NULL;
	ts->nsections = 0;
	ts->sections_cap = 0;
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
 * Returns buf on success, NULL on failure.
 */
const char *
process_name(pid_t pid, char *buf, size_t bufsz)
{
	int mib[4];
	size_t len;
	char *p;

	mib[0] = CTL_KERN;
	mib[1] = KERN_PROC;
	mib[2] = KERN_PROC_PATHNAME;
	mib[3] = pid;
	len = bufsz;

	if (sysctl(mib, 4, buf, &len, NULL, 0) != 0)
		return (NULL);

	/* Return just the basename. */
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

	if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0) {
		printf("bsdtrace %s\n", BSDTRACE_VERSION);
		return (0);
	}

	fprintf(stderr, "bsdtrace: unknown command '%s'\n", argv[1]);
	usage();
	/* NOTREACHED */
	return (1);
}
