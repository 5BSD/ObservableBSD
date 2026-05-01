/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Trace state — shared accumulator for exec/trace polling loops,
 * plus the snapshot-and-decode sequence used by both commands.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/sysctl.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	POST_STOP_MAX_RECORDS	256
#define	POST_STOP_EMPTY_POLLS	40
#define	POST_STOP_SLEEP_US	5000
#define	POLL_RECORDS		256

/* ------------------------------------------------------------------ */
/* Trace state accumulator                                             */
/* ------------------------------------------------------------------ */

static int
trace_state_add_section(struct trace_state *ts, const char *path,
    uint64_t load_addr, uint64_t base_addr, int type)
{
	struct pt_image_info *newsecs;

	if (path == NULL || path[0] == '\0')
		return (-1);

	if (ts->nsections >= ts->sections_cap) {
		int newcap = ts->sections_cap == 0 ? 32 : ts->sections_cap * 2;

		newsecs = realloc(ts->sections,
		    (size_t)newcap * sizeof(*ts->sections));
		if (newsecs == NULL)
			return (-1);
		ts->sections = newsecs;
		ts->sections_cap = newcap;
	}

	strlcpy(ts->sections[ts->nsections].path, path,
	    sizeof(ts->sections[ts->nsections].path));
	ts->sections[ts->nsections].load_addr = load_addr;
	ts->sections[ts->nsections].base_addr = base_addr;
	ts->sections[ts->nsections].type = type;
	ts->nsections++;
	return (0);
}

static void
trace_state_reset_sections(struct trace_state *ts)
{

	free(ts->sections);
	ts->sections = NULL;
	ts->nsections = 0;
	ts->sections_cap = 0;
}

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

	if (rec->type == HWT_RECORD_OVERFLOW)
		ts->overflow_count++;

	if ((rec->type == HWT_RECORD_EXECUTABLE ||
	    rec->type == HWT_RECORD_MMAP ||
	    rec->type == HWT_RECORD_KERNEL) &&
	    rec->fullpath[0] != '\0') {
		/*
		 * EXECUTABLE denotes a fresh exec image load.  Any mappings
		 * seeded from a pre-exec address space are now stale.
		 */
		if (rec->type == HWT_RECORD_EXECUTABLE)
			trace_state_reset_sections(ts);
		(void)trace_state_add_section(ts, rec->fullpath, rec->addr,
		    rec->baseaddr, rec->type);
	}
}

int
trace_state_seed_process_mmaps(struct trace_state *ts, pid_t pid)
{
	struct pt_image_info *sections;
	int nsections, i;

	if (process_exec_mmaps(pid, &sections, &nsections) != 0)
		return (-1);

	if (sections == NULL || nsections == 0) {
		free(sections);
		return (0);
	}

	meta_writer_sections(ts->meta, sections, nsections);
	for (i = 0; i < nsections; i++) {
		(void)trace_state_add_section(ts, sections[i].path,
		    sections[i].load_addr, sections[i].base_addr,
		    sections[i].type);
	}

	free(sections);
	return (0);
}

void
trace_state_free(struct trace_state *ts)
{

	trace_state_reset_sections(ts);
}

int
trace_state_drain_post_stop(struct hwt_ctx *ctx, struct trace_state *ts)
{
	struct bsdtrace_record records[POST_STOP_MAX_RECORDS];
	int empty_polls, i, nrecs, total;

	total = 0;
	empty_polls = 0;

	/*
	 * BUFFER records are queued asynchronously from the PT PMI path.
	 * After HWT_IOC_STOP, keep draining briefly while ctx_fd remains
	 * open so late taskqueue delivery can update the final extent.
	 */
	while (empty_polls < POST_STOP_EMPTY_POLLS) {
		nrecs = 0;
		if (hwt_ctx_poll_records(ctx, records, POST_STOP_MAX_RECORDS,
		    false, &nrecs) != 0)
			break;

		if (nrecs == 0) {
			empty_polls++;
			usleep(POST_STOP_SLEEP_US);
			continue;
		}

		empty_polls = 0;
		for (i = 0; i < nrecs; i++) {
			trace_state_process(ts, &records[i]);
			total++;
		}
	}

	return (total);
}

/* ------------------------------------------------------------------ */
/* Snapshot and decode — shared between cmd_exec and cmd_trace         */
/* ------------------------------------------------------------------ */

static size_t
pt_scan_last_nonzero(const uint8_t *buf, size_t len)
{

	while (len > 0 && buf[len - 1] == 0)
		len--;
	return (len);
}

static bool
probe_result_better(const struct decode_probe_result *a,
    const struct decode_probe_result *b)
{

	if (a->exec_hits != b->exec_hits)
		return (a->exec_hits > b->exec_hits);
	return (a->total > b->total);
}

/*
 * Pick the most plausible PT extent from the kernel-reported buffer
 * position and a conservative scan for the last non-zero byte.
 *
 * The stop pointer can under-report (lost ToPA page index) or
 * over-report (include long zero-padded tails).  Probe both candidates
 * when we have image sections and prefer the one that yields more
 * decoded instructions in the main executable.
 */
static size_t
choose_snapshot_len(const uint8_t *buf, size_t bufsz, size_t base_len,
    const struct pt_image_info *sections, int nsections)
{
	struct decode_probe_result base_probe, scan_probe;
	size_t scan_end, chosen;
	int base_rc, scan_rc;
	bool base_ok, scan_ok;

	if (buf == NULL || bufsz == 0)
		return (0);

	if (base_len > bufsz)
		base_len = bufsz;

	scan_end = pt_scan_last_nonzero(buf, bufsz);
	if (base_len == 0)
		return (scan_end);
	if (scan_end == 0 || scan_end == base_len)
		return (base_len);

	chosen = base_len;
	base_ok = false;
	scan_ok = false;

	if (nsections > 0) {
		memset(&base_probe, 0, sizeof(base_probe));
		memset(&scan_probe, 0, sizeof(scan_probe));

		base_rc = decode_pt_probe(buf, base_len,
		    sections, nsections, &base_probe);
		scan_rc = decode_pt_probe(buf, scan_end,
		    sections, nsections, &scan_probe);
		base_ok = base_rc == 0;
		scan_ok = scan_rc == 0;

		if (scan_ok &&
		    (!base_ok || probe_result_better(&scan_probe,
		    &base_probe)))
			chosen = scan_end;
		else if (!base_ok && !scan_ok && scan_end < base_len)
			chosen = scan_end;
	} else if (scan_end < base_len) {
		chosen = scan_end;
	}

	if (chosen == base_len && base_len < PAGE_SIZE && scan_end > base_len)
		chosen = scan_end;

	return (chosen);
}

ssize_t
snapshot_and_decode(struct hwt_ctx *ctx, struct trace_state *ts,
    const char *pt_output, enum bsdtrace_fmt fmt,
    const struct pt_decode_opts *opts)
{
	const uint8_t *buf;
	struct pt_decode_opts dopts;
	size_t actual_len, known_end, record_len, stop_len;
	int actual_page;
	vm_offset_t actual_offset;
	ssize_t saved;

	/*
	 * HWT_IOC_STOP clears TraceEn, then reads the now-stable
	 * OUTPUT_MASK_PTRS MSR.  BUFPTR_GET returns this exact value.
	 *
	 * Some patched kernels still report only the within-page offset
	 * here (page index lost), so keep the last HWT_RECORD_BUFFER
	 * extent as a lower-bound fallback and do a bounded look-ahead.
	 */
	stop_len = 0;
	if (hwt_ctx_bufptr_get(ctx, &actual_page, &actual_offset) != 0) {
		warnx("cannot read buffer position");
	} else {
		stop_len = (size_t)actual_page * PAGE_SIZE + actual_offset;
	}

	record_len = 0;
	if (ts->last_buf_page >= 0)
		record_len = (size_t)ts->last_buf_page * PAGE_SIZE +
		    ts->last_buf_offset;

	if (stop_len > ctx->bufsize)
		stop_len = 0;
	if (record_len > ctx->bufsize)
		record_len = 0;

	/*
	 * Trust the explicit stop pointer when it is sane and not behind the
	 * last async BUFFER record.  Only fall back to the old bounded scan
	 * when the stop ioctl appears to have lost the ToPA page index.
	 */
	known_end = stop_len == 0 ||
	    (record_len > 0 && stop_len < record_len) ?
	    record_len : stop_len;

	buf = hwt_ctx_map_buffer(ctx);
	if (buf == NULL)
		return (-1);

	memset(&dopts, 0, sizeof(dopts));
	dopts.tid = opts != NULL ? opts->tid : ctx->tid;
	dopts.mtc_freq = (uint8_t)ctx->mtc_freq;
	dopts.cyc_thresh = (uint8_t)ctx->cyc_thresh;
	if (opts != NULL) {
		dopts.filter_funcs = opts->filter_funcs;
		dopts.nfilter_funcs = opts->nfilter_funcs;
	}

	actual_len = choose_snapshot_len(buf, ctx->bufsize, known_end,
	    ts->sections, ts->nsections);
	if (actual_len == 0) {
		warnx("PT buffer is empty");
		return (0);
	}

	saved = hwt_ctx_snapshot_buffer(ctx, pt_output,
	    (int)(actual_len / PAGE_SIZE),
	    actual_len % PAGE_SIZE);
	if (saved > 0) {
		fprintf(stderr,
		    "Saved %zd bytes of PT data to %s\n",
		    saved, pt_output);
		decode_pt_insn(buf, (size_t)saved,
		    ts->sections, ts->nsections, fmt, &dopts);
	}

	/*
	 * Snapshot and decode additional threads.
	 *
	 * Each thread has its own PT buffer accessed via its own device
	 * fd.  The image sections (binary mappings) are shared — all
	 * threads in the process see the same address space.
	 */
	if ((ctx->all_threads || ctx->nrequested > 0) &&
	    ctx->nthreads > 0) {
		ssize_t thread_saved;
		char tpath[MAXPATHLEN];
		size_t baselen;
		int i;

		baselen = strlen(pt_output);
		if (baselen > 3 &&
		    strcmp(pt_output + baselen - 3, ".pt") == 0)
			baselen -= 3;

		for (i = 0; i < ctx->nthreads; i++) {
			struct hwt_thread_ctx *tc = &ctx->threads[i];
			struct hwt_bufptr_get bg;
			const uint8_t *tbuf;
			size_t tlen;
			int tpage;
			int ident_val = 0;
			vm_offset_t toffset, off_val = 0;
			ssize_t tnw;
			size_t toff;
			int tfd;

			/*
			 * Read buffer position and mmap the buffer.
			 * Use the same fallback as the primary thread:
			 * if BUFPTR_GET loses the page index, scan
			 * backward from the end of the buffer.
			 */
			memset(&bg, 0, sizeof(bg));
			bg.ident = &ident_val;
			bg.offset = &off_val;
			bg.data = NULL;

			tlen = 0;
			if (ioctl(tc->fd, HWT_IOC_BUFPTR_GET,
			    &bg) == 0) {
				tlen = (size_t)ident_val * PAGE_SIZE +
				    off_val;
			}
			if (tlen > ctx->bufsize)
				tlen = 0;

			/* mmap the thread's buffer. */
			if (tc->trace_buf == NULL) {
				tc->trace_buf = mmap(NULL, ctx->bufsize,
				    PROT_READ, MAP_SHARED, tc->fd, 0);
				if (tc->trace_buf == MAP_FAILED) {
					warn("mmap thread %d buffer",
					    tc->thread_id);
					tc->trace_buf = NULL;
					continue;
				}
			}
			tbuf = tc->trace_buf;

			tlen = choose_snapshot_len(tbuf, ctx->bufsize, tlen,
			    ts->sections, ts->nsections);

			if (tlen == 0) {
				fprintf(stderr,
				    "thread %d: PT buffer empty, "
				    "skipping\n", tc->thread_id);
				continue;
			}

			/* Build per-thread output path. */
			snprintf(tpath, sizeof(tpath), "%.*s-tid%d.pt",
			    (int)baselen, pt_output, tc->thread_id);

			tfd = open(tpath, O_WRONLY | O_CREAT | O_TRUNC,
			    0644);
			if (tfd < 0) {
				warn("open %s", tpath);
				continue;
			}

			toff = 0;
			while (toff < tlen) {
				tnw = write(tfd, tbuf + toff, tlen - toff);
				if (tnw < 0) {
					warn("write %s", tpath);
					break;
				}
				toff += tnw;
			}
			close(tfd);

			if (toff == tlen) {
				char tmeta[MAXPATHLEN];
				struct meta_writer *tmw;

				fprintf(stderr,
				    "Saved %zu bytes of PT data for "
				    "thread %d to %s\n",
				    tlen, tc->thread_id, tpath);

				/*
				 * Write a per-thread .meta sidecar so the
				 * .pt file is replayable offline with the
				 * correct tid.
				 */
				derive_meta_path(tpath, tmeta,
				    sizeof(tmeta));
				tmw = meta_writer_open(tmeta);
				if (tmw != NULL) {
					meta_writer_header(tmw,
					    ctx->pid, tc->thread_id);
					meta_writer_timing(tmw,
					    (uint8_t)ctx->mtc_freq,
					    (uint8_t)ctx->cyc_thresh);
					meta_writer_sections(tmw,
					    ts->sections, ts->nsections);
					meta_writer_close(tmw);
				}

				dopts.tid = tc->thread_id;
				if (fmt == FMT_TEXT)
					printf("Thread %d:\n",
					    tc->thread_id);
				decode_pt_insn(tbuf, tlen,
				    ts->sections, ts->nsections,
				    fmt, &dopts);
				thread_saved = (ssize_t)tlen;
				if (saved >= 0)
					saved += thread_saved;
			}
		}
	}

	return (saved);
}

/* ------------------------------------------------------------------ */
/* Shared helpers for cmd_exec / cmd_trace                             */
/* ------------------------------------------------------------------ */

void
emit_and_process(const struct bsdtrace_record *rec, pid_t pid,
    enum bsdtrace_fmt fmt, bool pause_on_mmap, struct hwt_ctx *ctx,
    struct trace_state *ts)
{

	if (fmt == FMT_JSON)
		fmt_record_json(rec, pid);
	else if (fmt == FMT_TEXT)
		fmt_record_text(rec, pid);

	if (pause_on_mmap &&
	    (rec->type == HWT_RECORD_MMAP ||
	     rec->type == HWT_RECORD_EXECUTABLE))
		hwt_ctx_wakeup(ctx);

	/*
	 * Open new thread devices as the kernel reports them.
	 * In all-threads mode, open every thread.  In multi-thread
	 * mode (-T 0,1,3), only open threads in the requested list.
	 */
	if (rec->type == HWT_RECORD_THREAD_CREATE &&
	    rec->thread_id != ctx->tid) {
		bool want = ctx->all_threads;
		if (!want) {
			for (int t = 0; t < ctx->nrequested; t++) {
				if (ctx->requested_tids[t] == rec->thread_id) {
					want = true;
					break;
				}
			}
		}
		if (want)
			hwt_ctx_open_thread(ctx, rec->thread_id,
			    pause_on_mmap);
	}

	trace_state_process(ts, rec);
}

/*
 * Resolve the HWT backend.  Returns the backend name (caller must
 * free *detected_out if non-NULL) or NULL on failure.  Prints
 * diagnostics to stderr.
 */
const char *
resolve_backend(const char *explicit_name, char **detected_out,
    bool dryrun)
{

	*detected_out = NULL;

	if (!hwt_available()) {
		fprintf(stderr,
		    "bsdtrace: /dev/hwt not found — run: sudo kldload hwt\n");
		return (NULL);
	}

	if (explicit_name != NULL)
		return (explicit_name);

	*detected_out = hwt_detect_backend();
	if (*detected_out == NULL) {
		fprintf(stderr,
		    "bsdtrace: no HWT backend loaded — "
		    "run: sudo kldload pt\n");
		return (NULL);
	}
	return (*detected_out);
}

/*
 * Check that the running kernel has HWT_HOOKS.  Returns 0 on success,
 * -1 on fatal failure.
 */
int
check_hwt_hooks(bool dryrun)
{
	int hooks;

	hooks = hwt_hooks_enabled();
	if (hooks == 0) {
		fprintf(stderr,
		    "bsdtrace: running kernel lacks HWT_HOOKS; "
		    "only alloc-time THREAD_CREATE records are available. "
		    "Boot a kernel built with 'options HWT_HOOKS'.\n");
		return (dryrun ? 0 : -1);
	}
	if (hooks < 0) {
		fprintf(stderr,
		    "bsdtrace: warning: unable to verify HWT_HOOKS in "
		    "the running kernel; continuing\n");
	}
	return (0);
}

/*
 * Derive the .meta sidecar path from the PT output path.
 */
void
derive_meta_path(const char *pt_output, char *meta_path, size_t meta_pathsz)
{
	size_t plen;

	plen = strlen(pt_output);
	if (plen > 3 && strcmp(pt_output + plen - 3, ".pt") == 0)
		snprintf(meta_path, meta_pathsz,
		    "%.*s.meta", (int)(plen - 3), pt_output);
	else
		snprintf(meta_path, meta_pathsz,
		    "%s.meta", pt_output);
}

/*
 * Ensure the kernel ELF is in the sections array when -K is active.
 * Older kernels may not emit HWT_RECORD_KERNEL records, so fall back
 * to reading the base address from sysctl kern.base_address.
 */
static void
trace_state_ensure_kernel(struct trace_state *ts)
{
	uint64_t kbase;
	size_t klen;
	int i;

	for (i = 0; i < ts->nsections; i++) {
		if (ts->sections[i].type == HWT_RECORD_KERNEL)
			return;
	}

	klen = sizeof(kbase);
	if (sysctlbyname("kern.base_address", &kbase, &klen, NULL, 0) != 0)
		return;

	(void)trace_state_add_section(ts, "/boot/kernel/kernel", kbase,
	    0, HWT_RECORD_KERNEL);
}

/*
 * Final drain, stop, snapshot, wrap warning, and cleanup.
 * Called at the end of both cmd_exec and cmd_trace.
 */
int
trace_finalize(struct hwt_ctx *ctx, struct trace_state *ts,
    struct meta_writer *meta, const char *pt_output, pid_t pid,
    enum bsdtrace_fmt fmt, int totalrecords,
    const struct pt_decode_opts *opts)
{
	struct bsdtrace_record records[POLL_RECORDS];
	ssize_t saved;
	int nrecs, i;

	/*
	 * Final drain before stopping.  Always wake the target on
	 * MMAP/EXEC records here — if pause-on-mmap was active and a
	 * late record arrives only in this drain, the target would stay
	 * suspended forever without the wakeup.
	 */
	nrecs = 0;
	if (hwt_ctx_poll_records(ctx, records, POLL_RECORDS,
	    false, &nrecs) == 0) {
		for (i = 0; i < nrecs; i++) {
			totalrecords++;
			emit_and_process(&records[i], pid, fmt,
			    true, ctx, ts);
		}
	}

	hwt_ctx_stop(ctx);
	totalrecords += trace_state_drain_post_stop(ctx, ts);

	if (ctx->os_trace)
		trace_state_ensure_kernel(ts);

	saved = snapshot_and_decode(ctx, ts, pt_output, fmt, opts);

	if (ts->buf_wrapped)
		fprintf(stderr,
		    "warning: PT buffer wrapped (data lost) — "
		    "increase with -s\n");
	if (ts->overflow_count > 0)
		fprintf(stderr,
		    "warning: %d PT internal overflow(s) — "
		    "trace data was lost, increase buffer with -s\n",
		    ts->overflow_count);

	/*
	 * Intel PT needs a PSB (Packet Stream Boundary) to sync the
	 * decoder.  PSBs are emitted roughly every 2-4 KB of output.
	 * If an IP range filter is active and the traced code didn't
	 * execute enough times, the .pt file may be too small for
	 * the decoder to find a sync point — producing 0 instructions.
	 */
	if (ctx->filter.nranges > 0 && saved >= 0 && saved < 2048)
		fprintf(stderr,
		    "warning: only %zd bytes of PT data with range filter "
		    "active — the decoder likely cannot sync (needs ~2 KB).\n"
		    "  Make the traced code run more iterations, or widen "
		    "the filter range.\n", saved);

	hwt_ctx_close(ctx);
	meta_writer_close(meta);
	trace_state_free(ts);

	if (saved < 0)
		return (-1);
	return (totalrecords);
}
