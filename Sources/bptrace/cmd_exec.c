/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bptrace exec — run a command under HWT tracing and report events.
 *
 * Forks the child stopped (via raise(SIGSTOP)), attaches HWT
 * thread-mode tracing, resumes the child, and collects records
 * until it exits or timeout.
 */

#include <sys/types.h>
#include <sys/wait.h>

#include <err.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "bptrace.h"

#define	DEFAULT_TIMEOUT		30.0
#define	DEFAULT_BUFSIZE		"4m"
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
fork_stopped(char **args)
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
		raise(SIGSTOP);
		execvp(args[0], args);
		_exit(127);
	}

	/* Parent — wait for child to stop. */
	waitpid(pid, &status, WUNTRACED);
	if (!WIFSTOPPED(status)) {
		warnx("child did not stop as expected");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		return (-1);
	}

	return (pid);
}

/* ------------------------------------------------------------------ */
/* Record polling loop                                                 */
/* ------------------------------------------------------------------ */

static void
emit_record(const struct bptrace_record *rec, pid_t pid,
    enum bptrace_fmt fmt, bool pause_on_mmap, struct hwt_ctx *ctx)
{

	if (fmt == FMT_JSON)
		fmt_record_json(rec, pid);
	else
		fmt_record_text(rec, pid);

	if (pause_on_mmap &&
	    (rec->type == HWT_RECORD_MMAP ||
	     rec->type == HWT_RECORD_EXECUTABLE))
		hwt_ctx_wakeup(ctx);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_exec(int argc, char **argv)
{
	struct bptrace_record records[MAX_POLL_RECORDS];
	struct pt_image_info sections[MAX_IMAGE_SECTIONS];
	int nsections;
	struct hwt_ctx ctx;
	struct timespec start, now;
	enum bptrace_fmt fmt;
	const char *bufsize_str;
	const char *backend_name;
	char *detected_backend;
	double timeout;
	size_t bufsize;
	pid_t child;
	char pt_path[64];
	const char *pt_output;
	int last_buf_page;
	vm_offset_t last_buf_offset;
	int hooks;
	int maxrecords;
	int totalrecords;
	int exitcode;
	int empty_drains;
	int nrecs;
	int status;
	int ch, i;
	bool dryrun;
	bool pause_on_mmap;
	bool child_done;
	char **cmd_argv;

	fmt = FMT_TEXT;
	bufsize_str = DEFAULT_BUFSIZE;
	backend_name = NULL;
	detected_backend = NULL;
	pt_output = NULL;
	timeout = DEFAULT_TIMEOUT;
	maxrecords = 0;
	last_buf_page = -1;
	last_buf_offset = 0;
	nsections = 0;
	dryrun = false;
	pause_on_mmap = false;

	optind = 1;
	while ((ch = getopt(argc, argv, "f:b:s:t:m:o:np")) != -1) {
		switch (ch) {
		case 'f':
			if (strcmp(optarg, "json") == 0)
				fmt = FMT_JSON;
			else if (strcmp(optarg, "text") == 0)
				fmt = FMT_TEXT;
			else {
				fprintf(stderr,
				    "bptrace exec: unknown format '%s'\n",
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
		case 't':
			timeout = atof(optarg);
			break;
		case 'm':
			maxrecords = atoi(optarg);
			break;
		case 'o':
			pt_output = optarg;
			break;
		case 'n':
			dryrun = true;
			break;
		case 'p':
			pause_on_mmap = true;
			break;
		default:
			fprintf(stderr,
			    "usage: bptrace exec [opts] -- cmd [args...]\n");
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
		    "bptrace exec: provide a command after '--'\n");
		return (1);
	}
	cmd_argv = argv;

	if (!hwt_available()) {
		fprintf(stderr,
		    "bptrace: /dev/hwt not found — run: sudo kldload hwt\n");
		return (1);
	}

	bufsize = parse_size(bufsize_str);

	/* Resolve backend. */
	if (backend_name == NULL) {
		detected_backend = hwt_detect_backend();
		backend_name = detected_backend;
	}
	if (backend_name == NULL) {
		fprintf(stderr,
		    "bptrace: no HWT backend loaded — "
		    "run: sudo kldload pt\n");
		return (1);
	}

	hooks = hwt_hooks_enabled();
	if (hooks == 0) {
		fprintf(stderr,
		    "bptrace: running kernel lacks HWT_HOOKS; "
		    "only alloc-time THREAD_CREATE records are available. "
		    "Boot a kernel built with 'options HWT_HOOKS'.\n");
		free(detected_backend);
		return (dryrun ? 0 : 1);
	}
	if (hooks < 0) {
		fprintf(stderr,
		    "bptrace: warning: unable to verify HWT_HOOKS in "
		    "the running kernel; continuing\n");
	}

	/* Fork child stopped. */
	child = fork_stopped(cmd_argv);
	if (child < 0)
		return (1);

	/* Allocate HWT context for the child. */
	if (hwt_ctx_alloc(&ctx, HWT_MODE_THREAD, child,
	    bufsize, backend_name) != 0) {
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		free(detected_backend);
		return (1);
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

	kill(child, SIGCONT);
	clock_gettime(CLOCK_MONOTONIC, &start);

	/* Poll records until child exits or timeout. */
	child_done = false;
	exitcode = 0;
	totalrecords = 0;
	empty_drains = 0;

	for (;;) {
		/* Check timeout. */
		clock_gettime(CLOCK_MONOTONIC, &now);
		double elapsed = (now.tv_sec - start.tv_sec) +
		    (now.tv_nsec - start.tv_nsec) / 1e9;
		if (timeout > 0 && elapsed >= timeout) {
			fprintf(stderr,
			    "timeout: %.0fs elapsed, stopping trace\n",
			    timeout);
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
			emit_record(&records[i], child, fmt,
			    pause_on_mmap, &ctx);
			if (records[i].type == HWT_RECORD_BUFFER) {
				last_buf_page = records[i].curpage;
				last_buf_offset = records[i].offset;
			}
			if ((records[i].type == HWT_RECORD_EXECUTABLE ||
			    records[i].type == HWT_RECORD_MMAP) &&
			    records[i].fullpath[0] != '\0' &&
			    nsections < MAX_IMAGE_SECTIONS) {
				strlcpy(sections[nsections].path,
				    records[i].fullpath,
				    sizeof(sections[nsections].path));
				sections[nsections].load_addr =
				    records[i].addr;
				sections[nsections].base_addr =
				    records[i].baseaddr;
				sections[nsections].type =
				    records[i].type;
				nsections++;
			}
		}

		/*
		 * Once the child exits, keep draining a few times before
		 * closing ctx_fd.  We cannot rely on a post-stop drain
		 * because the PT-safe stop path closes the device.
		 */
		if (child_done) {
			if (nrecs == 0) {
				empty_drains++;
				if (empty_drains >= 3)
					break;
			} else {
				empty_drains = 0;
			}
		}

		usleep(nrecs > 0 ? 100 : 1000);
	}

	/* Reap child if we killed it above (timeout/maxrecords). */
	if (!child_done) {
		status = 0;
		waitpid(child, &status, 0);
		if (WIFEXITED(status))
			exitcode = WEXITSTATUS(status);
		else if (WIFSIGNALED(status))
			exitcode = 128 + WTERMSIG(status);
	}

	/*
	 * Final drain while the context fd is still open.
	 * The loop above handles most draining, but one more pass
	 * catches any records that arrived after the last poll.
	 */
	nrecs = 0;
	if (hwt_ctx_poll_records(&ctx, records, MAX_POLL_RECORDS,
	    false, &nrecs) == 0) {
		for (i = 0; i < nrecs; i++) {
			totalrecords++;
			emit_record(&records[i], child, fmt,
			    pause_on_mmap, &ctx);
			if (records[i].type == HWT_RECORD_BUFFER) {
				last_buf_page = records[i].curpage;
				last_buf_offset = records[i].offset;
			}
			if ((records[i].type == HWT_RECORD_EXECUTABLE ||
			    records[i].type == HWT_RECORD_MMAP) &&
			    records[i].fullpath[0] != '\0' &&
			    nsections < MAX_IMAGE_SECTIONS) {
				strlcpy(sections[nsections].path,
				    records[i].fullpath,
				    sizeof(sections[nsections].path));
				sections[nsections].load_addr =
				    records[i].addr;
				sections[nsections].base_addr =
				    records[i].baseaddr;
				sections[nsections].type =
				    records[i].type;
				nsections++;
			}
		}
	}

	/* Snapshot PT buffer before stop closes the context fd. */
	if (last_buf_page >= 0) {
		ssize_t saved;

		if (pt_output == NULL) {
			snprintf(pt_path, sizeof(pt_path),
			    "bptrace-%d.pt", (int)child);
			pt_output = pt_path;
		}
		saved = hwt_ctx_snapshot_buffer(&ctx, pt_output,
		    last_buf_page, last_buf_offset);
		if (saved > 0) {
			fprintf(stderr,
			    "Saved %zd bytes of PT data to %s\n",
			    saved, pt_output);
			decode_pt_insn(ctx.trace_buf, (size_t)saved,
			    sections, nsections, fmt);
		}
	}

	/* Stop tracing (closes ctx_fd; no drain possible after this). */
	hwt_ctx_stop(&ctx);

	if (fmt == FMT_TEXT)
		fprintf(stderr, "\n%d records collected, exit code %d\n",
		    totalrecords, exitcode);

	hwt_ctx_close(&ctx);
	free(detected_backend);
	return (exitcode);
}
