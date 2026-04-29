/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace exec — run a command under HWT tracing and report events.
 *
 * Forks the child stopped (via raise(SIGSTOP)), attaches HWT
 * thread-mode tracing, resumes the child, and collects records
 * until it exits or duration.
 */

#include <sys/types.h>
#include <sys/procctl.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <err.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	DEFAULT_DURATION		30.0
#define	DEFAULT_BUFSIZE		"64m"
#define	MAX_POLL_RECORDS	256

/* ------------------------------------------------------------------ */
/* Fork helper                                                         */
/* ------------------------------------------------------------------ */


/*
 * Fork the child, have it raise(SIGSTOP) before exec.
 * Parent waits for the stop, then returns the child PID.
 *
 * Only async-signal-safe / POSIX calls in the child path.
 * No Swift runtime, no ARC, no closures — just C.
 */
static pid_t
fork_stopped(char **args, bool no_aslr)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid == -1) {
		warn("fork");
		return (-1);
	}
	if (pid == 0) {
		/* Child — only async-signal-safe calls. */
		if (no_aslr) {
			int val = PROC_ASLR_FORCE_DISABLE;
			procctl(P_PID, getpid(), PROC_ASLR_CTL, &val);
		}
		raise(SIGSTOP);
		execvp(args[0], args);
		_exit(127);
	}

	/* Parent — wait for child to stop. */
	if (waitpid(pid, &status, WUNTRACED) < 0) {
		warn("waitpid");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return (-1);
	}
	if (!WIFSTOPPED(status)) {
		warnx("child did not stop as expected");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return (-1);
	}

	return (pid);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_exec(int argc, char **argv)
{
	struct bsdtrace_record records[MAX_POLL_RECORDS];
	struct trace_state ts;
	struct hwt_ctx ctx;
	struct timespec start, now;
	struct meta_writer *meta;
	enum bsdtrace_fmt fmt;
	const char *bufsize_str;
	const char *backend_name;
	char *detected_backend;
	double duration;
	size_t bufsize;
	pid_t child;
	char pt_path[64];
	char meta_path[MAXPATHLEN];
	const char *pt_output;
	struct ip_filter filter;
	struct range_spec range_specs[2];
	int nrange_specs;
	int tid;
	bool trace_all_threads;
	int requested_tids[MAX_THREADS];
	int nrequested_tids;
	int maxrecords;
	bool no_aslr;
	int totalrecords;
	int exitcode;
	int empty_drains;
	int nrecs;
	int status;
	int ch, i;
	int psb_freq;
	bool timing;
	bool dryrun;
	bool pause_on_mmap;
	bool child_done;
	char **cmd_argv;

	fmt = FMT_TEXT;
	bufsize_str = DEFAULT_BUFSIZE;
	backend_name = NULL;
	detected_backend = NULL;
	pt_output = NULL;
	duration = DEFAULT_DURATION;
	maxrecords = 0;
	tid = 0;
	trace_all_threads = false;
	nrequested_tids = 0;
	memset(&filter, 0, sizeof(filter));
	nrange_specs = 0;
	no_aslr = false;
	psb_freq = 0;
	timing = false;
	dryrun = false;
	pause_on_mmap = false;

	optind = 1;
	while ((ch = getopt(argc, argv, "f:b:s:d:t:m:o:r:T:P:AhnpC")) != -1) {
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
			else if (strcmp(optarg, "collapsed") == 0)
				fmt = FMT_COLLAPSED;
			else {
				fprintf(stderr,
				    "bsdtrace exec: unknown format '%s'\n",
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
				    "bsdtrace exec: max 2 IP ranges\n");
				return (1);
			}
			if (parse_range_spec(optarg,
			    &range_specs[nrange_specs]) != 0)
				return (1);
			nrange_specs++;
			break;
		case 'T':
			if (strcmp(optarg, "all") == 0) {
				tid = 0;
				trace_all_threads = true;
			} else if (strchr(optarg, ',') != NULL) {
				/* Comma-separated list: -T 0,1,3 */
				char *tstr, *tok, *saveptr;
				tstr = strdup(optarg);
				nrequested_tids = 0;
				tok = strtok_r(tstr, ",", &saveptr);
				while (tok != NULL &&
				    nrequested_tids < MAX_THREADS) {
					requested_tids[nrequested_tids++] =
					    atoi(tok);
					tok = strtok_r(NULL, ",", &saveptr);
				}
				free(tstr);
				if (nrequested_tids < 1) {
					fprintf(stderr,
					    "bsdtrace exec: -T requires "
					    "at least one thread id\n");
					return (1);
				}
				tid = requested_tids[0];
			} else {
				tid = atoi(optarg);
			}
			break;
		case 'A':
			no_aslr = true;
			break;
		case 'n':
			dryrun = true;
			break;
		case 'p':
			pause_on_mmap = true;
			break;
		case 'P':
			psb_freq = atoi(optarg);
			if (psb_freq < 0 || psb_freq > 15) {
				fprintf(stderr,
				    "bsdtrace exec: psb-freq must be "
				    "0-15\n");
				return (1);
			}
			break;
		case 'C':
			timing = true;
			break;
		case 'h':
			fprintf(stderr,
			    "usage: bsdtrace exec [options] -- command [args...]\n"
			    "\n"
			    "Run a command under hardware trace and decode the results.\n"
			    "\n"
			    "Options:\n"
			    "  -f format   Output format: text, json, profile, tree, or collapsed\n"
			    "  -d seconds  Maximum trace duration (default: 30)\n"
			    "  -s size     Trace buffer size, e.g. 8m, 64m (default: 64m)\n"
			    "  -o file     Output path for .pt data (default: bsdtrace-<pid>.pt)\n"
			    "  -r range    IP filter: 0xstart:0xend or function_name (up to 2)\n"
			    "  -T tid       Thread index (default: 0), list (0,1,3), or 'all'\n"
			    "  -m count    Stop after N records\n"
			    "  -b backend  HWT backend name (default: auto-detect)\n"
			    "  -P freq     PSB sync frequency 0-15 (lower = more sync, 0 = default)\n"
			    "  -C          Enable timing packets (MTC + cycle-accurate)\n"
			    "  -A          Disable ASLR for the child process\n"
			    "  -p          Pause target on mmap/exec events\n"
			    "  -n          Dry run: validate setup without tracing\n"
			    "  -h          Show this help\n");
			return (0);
		default:
			fprintf(stderr,
			    "usage: bsdtrace exec [options] -- command [args...]\n"
			    "       (use -h for help)\n");
			return (1);
		}
	}
	argc -= optind;
	argv += optind;

	/* Skip "--" separator if present. */
	if (argc > 0 && strcmp(argv[0], "--") == 0) {
		argc--;
		argv++;
	}

	if (argc < 1) {
		fprintf(stderr,
		    "bsdtrace exec: provide a command after '--'\n");
		return (1);
	}
	cmd_argv = argv;

	/* Resolve symbol-based range specs before forking.
	 * If the command is a bare name (no '/'), resolve via PATH
	 * so symbol lookup can find the ELF binary. */
	if (nrange_specs > 0) {
		bool need_aslr_disable;
		char resolved_cmd[MAXPATHLEN];
		const char *exe_for_symbols;

		exe_for_symbols = cmd_argv[0];
		if (strchr(cmd_argv[0], '/') == NULL) {
			const char *p = getenv("PATH");
			struct stat sb;

			resolved_cmd[0] = '\0';
			while (p != NULL && *p != '\0') {
				const char *end = strchr(p, ':');
				size_t len = end ? (size_t)(end - p) : strlen(p);

				snprintf(resolved_cmd, sizeof(resolved_cmd),
				    "%.*s/%s", (int)len, p, cmd_argv[0]);
				if (stat(resolved_cmd, &sb) == 0 &&
				    (sb.st_mode & S_IXUSR))
					break;
				resolved_cmd[0] = '\0';
				p = end ? end + 1 : NULL;
			}
			if (resolved_cmd[0] != '\0')
				exe_for_symbols = resolved_cmd;
		}

		if (resolve_range_specs(range_specs, nrange_specs,
		    &filter, 0, exe_for_symbols, true,
		    &need_aslr_disable) != 0)
			return (1);
		if (need_aslr_disable && !no_aslr) {
			fprintf(stderr,
			    "note: disabling ASLR for symbol-based "
			    "range filter\n");
			no_aslr = true;
		}
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

	/* Fork child stopped. */
	child = fork_stopped(cmd_argv, no_aslr);
	if (child < 0)
		return (1);

	/* Allocate HWT context for the child. */
	if (hwt_ctx_alloc(&ctx, HWT_MODE_THREAD, child, tid,
	    bufsize, backend_name) != 0) {
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		free(detected_backend);
		return (1);
	}

	/* Apply hardware IP range filter if specified. */
	ctx.filter = filter;
	ctx.psb_freq = psb_freq;
	ctx.all_threads = trace_all_threads;
	if (nrequested_tids > 0) {
		memcpy(ctx.requested_tids, requested_tids,
		    nrequested_tids * sizeof(int));
		ctx.nrequested = nrequested_tids;
	}
	if (timing) {
		hwt_pt_default_timing(&ctx.mtc_freq, &ctx.cyc_thresh);
		if (ctx.mtc_freq == 0 && ctx.cyc_thresh == 0) {
			fprintf(stderr,
			    "bsdtrace exec: -C requested but CPU does "
			    "not support timing packets\n");
			kill(child, SIGKILL);
			waitpid(child, NULL, 0);
			hwt_ctx_close(&ctx);
			free(detected_backend);
			return (1);
		}
	}

	/*
	 * CRITICAL: Set the PT backend config BEFORE starting.
	 *
	 * The PT backend's pt_backend_configure() dereferences
	 * ctx->config on the first hwt_switch_in.  If config is
	 * NULL, the kernel page-faults.
	 */
	if (hwt_ctx_set_config(&ctx, pause_on_mmap) != 0) {
		hwt_ctx_close(&ctx);
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		free(detected_backend);
		return (1);
	}

	if (dryrun) {
		fprintf(stderr,
		    "dry-run: HWT context allocated OK "
		    "(ident=%d, backend=%s, bufsize=%zu)\n",
		    ctx.ident, backend_name, bufsize);
		hwt_ctx_close(&ctx);
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		free(detected_backend);
		return (0);
	}

	/* Start tracing and resume child. */
	if (hwt_ctx_start(&ctx) != 0) {
		hwt_ctx_close(&ctx);
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		free(detected_backend);
		return (1);
	}

	/* Resolve PT output path and open .meta sidecar. */
	if (pt_output == NULL) {
		snprintf(pt_path, sizeof(pt_path),
		    "bsdtrace-%d.pt", (int)child);
		pt_output = pt_path;
	}
	derive_meta_path(pt_output, meta_path, sizeof(meta_path));
	meta = meta_writer_open(meta_path);
	if (meta == NULL)
		warnx("could not create %s — continuing without metadata",
		    meta_path);
	meta_writer_header(meta, child, tid);
	meta_writer_timing(meta, (uint8_t)ctx.mtc_freq);
	trace_state_init(&ts, meta);

	/* Line-buffer stdout — see cmd_trace.c comment.
	 * Ignore SIGPIPE so a closed stdout doesn't prevent cleanup. */
	setvbuf(stdout, NULL, _IOLBF, 0);
	signal(SIGPIPE, SIG_IGN);

	kill(child, SIGCONT);
	clock_gettime(CLOCK_MONOTONIC, &start);

	/* Poll records until child exits or duration. */
	child_done = false;
	exitcode = 0;
	totalrecords = 0;
	empty_drains = 0;

	for (;;) {
		/* Check duration. */
		clock_gettime(CLOCK_MONOTONIC, &now);
		double elapsed = (now.tv_sec - start.tv_sec) +
		    (now.tv_nsec - start.tv_nsec) / 1e9;
		if (duration > 0 && elapsed >= duration) {
			fprintf(stderr,
			    "duration: %.0fs elapsed, stopping trace\n",
			    duration);
			kill(child, SIGKILL);
			break;
		}

		/* Check max records. */
		if (maxrecords > 0 && totalrecords >= maxrecords) {
			fprintf(stderr,
			    "max-records: %d reached, stopping trace\n",
			    maxrecords);
			kill(child, SIGKILL);
			break;
		}

		/* Check child status (non-blocking). */
		status = 0;
		if (waitpid(child, &status, WNOHANG) > 0) {
			child_done = true;
			if (WIFEXITED(status))
				exitcode = WEXITSTATUS(status);
			else if (WIFSIGNALED(status))
				exitcode = 128 + WTERMSIG(status);
		}

		/* Drain records. */
		nrecs = 0;
		if (hwt_ctx_poll_records(&ctx, records, MAX_POLL_RECORDS,
		    false, &nrecs) != 0) {
			if (child_done)
				break;
			/*
			 * Poll error while child is still running.
			 * Kill child, reap, then fall through to cleanup.
			 */
			kill(child, SIGKILL);
			waitpid(child, &status, 0);
			child_done = true;
			exitcode = WIFSIGNALED(status) ?
			    128 + WTERMSIG(status) : 1;
			break;
		}

		for (i = 0; i < nrecs; i++) {
			totalrecords++;
			emit_and_process(&records[i], child, fmt,
			    pause_on_mmap, &ctx, &ts);
		}

		/*
		 * Once the child exits, keep draining a few times before
		 * closing ctx_fd.  We cannot rely on a post-stop drain
		 * because the PT-safe stop path closes the device.
		 */
		if (child_done) {
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

	/* Reap child if we killed it above (duration/maxrecords). */
	if (!child_done) {
		status = 0;
		waitpid(child, &status, 0);
		if (WIFEXITED(status))
			exitcode = WEXITSTATUS(status);
		else if (WIFSIGNALED(status))
			exitcode = 128 + WTERMSIG(status);
	}

	totalrecords = trace_finalize(&ctx, &ts, meta, pt_output,
	    child, fmt, totalrecords);

	if (fmt == FMT_TEXT)
		fprintf(stderr, "\n%d records collected, exit code %d\n",
		    totalrecords, exitcode);

	free(detected_backend);
	return (exitcode);
}
