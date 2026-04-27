/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace trace — attach HWT tracing to a running process.
 *
 * Attaches thread-mode tracing to the given PID and streams
 * records until interrupted (Ctrl-C), duration elapsed, or
 * the target exits.
 */

#include <sys/types.h>

#include <err.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	DEFAULT_BUFSIZE		"64m"
#define	MAX_POLL_RECORDS	256

/* Global flag set by SIGINT handler. */
static volatile sig_atomic_t trace_interrupted;

static void
sigint_handler(int sig __unused)
{

	trace_interrupted = 1;
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_trace(int argc, char **argv)
{
	struct bsdtrace_record records[MAX_POLL_RECORDS];
	struct trace_state ts;
	struct hwt_ctx ctx;
	struct timespec start, now;
	char pathbuf[1024];
	struct meta_writer *meta;
	char pt_path[64];
	char meta_path[MAXPATHLEN];
	const char *pt_output;
	enum bsdtrace_fmt fmt;
	const char *bufsize_str;
	const char *backend_name;
	const char *execname;
	char *detected_backend;
	double duration;
	size_t bufsize;
	pid_t pid;
	struct ip_filter filter;
	struct range_spec range_specs[2];
	int nrange_specs;
	int tid;
	int maxrecords;
	int totalrecords;
	int empty_drains;
	int nrecs;
	int ch, i;
	bool dryrun;
	bool pause_on_mmap;
	bool target_gone;

	fmt = FMT_TEXT;
	bufsize_str = DEFAULT_BUFSIZE;
	backend_name = NULL;
	detected_backend = NULL;
	pt_output = NULL;
	duration = 0;
	maxrecords = 0;
	tid = 0;
	memset(&filter, 0, sizeof(filter));
	nrange_specs = 0;
	dryrun = false;
	pause_on_mmap = false;

	optind = 1;
	while ((ch = getopt(argc, argv, "f:b:s:d:t:m:o:r:T:hnp")) != -1) {
		switch (ch) {
		case 'f':
			if (strcmp(optarg, "json") == 0)
				fmt = FMT_JSON;
			else if (strcmp(optarg, "text") == 0)
				fmt = FMT_TEXT;
			else if (strcmp(optarg, "profile") == 0)
				fmt = FMT_PROFILE;
			else if (strcmp(optarg, "tree") == 0)
				fmt = FMT_TREE;
			else {
				fprintf(stderr,
				    "bsdtrace trace: unknown format '%s'\n",
				    optarg);
				return (1);
			}
			break;
		case 'b':
			backend_name = optarg;
			break;
		case 's':
			bufsize_str = optarg;
			break;
		case 'd':
		case 't':
			duration = atof(optarg);
			break;
		case 'm':
			maxrecords = atoi(optarg);
			break;
		case 'o':
			pt_output = optarg;
			break;
		case 'r':
			if (nrange_specs >= 2) {
				fprintf(stderr,
				    "bsdtrace trace: max 2 IP ranges\n");
				return (1);
			}
			if (parse_range_spec(optarg,
			    &range_specs[nrange_specs]) != 0)
				return (1);
			nrange_specs++;
			break;
		case 'T':
			tid = atoi(optarg);
			break;
		case 'n':
			dryrun = true;
			break;
		case 'p':
			pause_on_mmap = true;
			break;
		case 'h':
			fprintf(stderr,
			    "usage: bsdtrace trace [options] pid\n"
			    "\n"
			    "Attach to a running process and trace it.\n"
			    "\n"
			    "Options:\n"
			    "  -f format   Output format: text, json, profile, or tree\n"
			    "  -d seconds  Trace duration (0 = until Ctrl-C, default)\n"
			    "  -s size     Trace buffer size, e.g. 8m, 64m (default: 64m)\n"
			    "  -o file     Output path for .pt data (default: bsdtrace-<pid>.pt)\n"
			    "  -r range    IP filter: 0xstart:0xend or function_name (up to 2)\n"
			    "  -T tid      Thread index to trace (default: 0, main thread)\n"
			    "  -m count    Stop after N records\n"
			    "  -b backend  HWT backend name (default: auto-detect)\n"
			    "  -p          Pause target on mmap/exec events\n"
			    "  -n          Dry run: validate setup without tracing\n"
			    "  -h          Show this help\n");
			return (0);
		default:
			fprintf(stderr,
			    "usage: bsdtrace trace [options] pid\n"
			    "       (use -h for help)\n");
			return (1);
		}
	}
	argc -= optind;
	argv += optind;

	if (argc < 1) {
		fprintf(stderr, "bsdtrace trace: PID required\n");
		return (1);
	}

	pid = (pid_t)atoi(argv[0]);
	if (pid <= 0) {
		fprintf(stderr, "bsdtrace trace: PID must be positive\n");
		return (1);
	}

	/* Verify target exists. */
	if (kill(pid, 0) != 0) {
		fprintf(stderr,
		    "bsdtrace trace: process %d not found or not accessible\n",
		    (int)pid);
		return (1);
	}

	bufsize = parse_size(bufsize_str);

	/* Resolve backend and check kernel support. */
	backend_name = resolve_backend(backend_name, &detected_backend,
	    dryrun);
	if (backend_name == NULL)
		return (1);
	if (check_hwt_hooks(dryrun) != 0) {
		free(detected_backend);
		return (dryrun ? 0 : 1);
	}

	execname = process_name(pid, pathbuf, sizeof(pathbuf));
	if (execname == NULL)
		execname = "?";

	/* Resolve any symbol-based range specs to addresses. */
	if (nrange_specs > 0) {
		char fullpath[MAXPATHLEN];
		bool unused_aslr;

		if (process_exe_fullpath(pid, fullpath,
		    sizeof(fullpath)) != 0) {
			warnx("cannot determine executable path for pid %d",
			    (int)pid);
			free(detected_backend);
			return (1);
		}
		if (resolve_range_specs(range_specs, nrange_specs,
		    &filter, pid, fullpath, false, &unused_aslr) != 0) {
			free(detected_backend);
			return (1);
		}
	}

	/* Allocate HWT context. */
	if (hwt_ctx_alloc(&ctx, HWT_MODE_THREAD, pid, tid,
	    bufsize, backend_name) != 0) {
		free(detected_backend);
		return (1);
	}

	/* Apply hardware IP range filter if specified. */
	ctx.filter = filter;

	/*
	 * CRITICAL: Set the PT backend config BEFORE starting.
	 * See hwt.c comments for why this prevents kernel panics.
	 */
	if (hwt_ctx_set_config(&ctx, pause_on_mmap) != 0) {
		hwt_ctx_close(&ctx);
		free(detected_backend);
		return (1);
	}

	if (dryrun) {
		fprintf(stderr,
		    "dry-run: HWT context allocated OK "
		    "(ident=%d, pid=%d, backend=%s, bufsize=%zu)\n",
		    ctx.ident, (int)pid, backend_name, bufsize);
		hwt_ctx_close(&ctx);
		free(detected_backend);
		return (0);
	}

	/* Install SIGINT handler for clean shutdown. */
	trace_interrupted = 0;
	signal(SIGINT, sigint_handler);

	if (hwt_ctx_start(&ctx) != 0) {
		hwt_ctx_close(&ctx);
		free(detected_backend);
		return (1);
	}

	/* Resolve PT output path now so the .meta sidecar is co-located. */
	if (pt_output == NULL) {
		snprintf(pt_path, sizeof(pt_path),
		    "bsdtrace-%d.pt", (int)pid);
		pt_output = pt_path;
	}
	derive_meta_path(pt_output, meta_path, sizeof(meta_path));
	meta = meta_writer_open(meta_path);
	if (meta == NULL)
		warnx("could not create %s — continuing without metadata",
		    meta_path);
	meta_writer_header(meta, pid, tid);
	trace_state_init(&ts, meta);

	clock_gettime(CLOCK_MONOTONIC, &start);
	totalrecords = 0;
	empty_drains = 0;
	target_gone = false;

	/*
	 * Line-buffer stdout so each JSON/text line is flushed as a
	 * single write().  Without this, the default full buffering
	 * (when piped) lets stderr writes interleave mid-line, producing
	 * malformed JSON when captured via 2>&1.
	 */
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (fmt == FMT_TEXT)
		fprintf(stderr, "Tracing PID %d (%s)...\n",
		    (int)pid, execname);

	while (!trace_interrupted) {
		/* Check duration. */
		if (!target_gone && duration > 0) {
			clock_gettime(CLOCK_MONOTONIC, &now);
			double elapsed = (now.tv_sec - start.tv_sec) +
			    (now.tv_nsec - start.tv_nsec) / 1e9;
			if (elapsed >= duration)
				break;
		}

		/* Check max records. */
		if (!target_gone && maxrecords > 0 && totalrecords >= maxrecords) {
			fprintf(stderr,
			    "max-records: %d reached, stopping trace\n",
			    maxrecords);
			break;
		}

		/*
		 * Once the target exits, keep draining a few times before
		 * closing ctx_fd.  We cannot rely on a post-stop drain
		 * because the PT-safe stop path closes the device.
		 */
		if (!target_gone && kill(pid, 0) != 0) {
			target_gone = true;
			if (fmt == FMT_TEXT)
				fprintf(stderr,
				    "Target process %d exited\n", (int)pid);
		}

		/* Drain records. */
		nrecs = 0;
		if (hwt_ctx_poll_records(&ctx, records, MAX_POLL_RECORDS,
		    false, &nrecs) != 0)
			break;

		for (i = 0; i < nrecs; i++) {
			totalrecords++;
			emit_and_process(&records[i], pid, fmt,
			    pause_on_mmap, &ctx, &ts);
		}

		if (target_gone) {
			if (nrecs == 0) {
				empty_drains++;
				if (empty_drains >= 5)
					break;
			} else {
				empty_drains = 0;
			}
		}

		usleep(nrecs > 0 ? 100 : 5000);
	}

	totalrecords = trace_finalize(&ctx, &ts, meta, pt_output,
	    pid, fmt, totalrecords);

	if (fmt == FMT_TEXT) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		double elapsed = (now.tv_sec - start.tv_sec) +
		    (now.tv_nsec - start.tv_nsec) / 1e9;
		fprintf(stderr, "\n%d records in %.3fs\n",
		    totalrecords, elapsed);
	}

	/* Restore default SIGINT. */
	signal(SIGINT, SIG_DFL);

	free(detected_backend);
	return (0);
}
