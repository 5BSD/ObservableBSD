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

#include <err.h>
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
		struct pt_image_info *newsecs;

		if (ts->nsections >= ts->sections_cap) {
			int newcap = ts->sections_cap == 0 ?
			    32 : ts->sections_cap * 2;
			newsecs = realloc(ts->sections,
			    newcap * sizeof(*ts->sections));
			if (newsecs == NULL)
				return;
			ts->sections = newsecs;
			ts->sections_cap = newcap;
		}
		strlcpy(ts->sections[ts->nsections].path,
		    rec->fullpath,
		    sizeof(ts->sections[ts->nsections].path));
		ts->sections[ts->nsections].load_addr = rec->addr;
		ts->sections[ts->nsections].base_addr = rec->baseaddr;
		ts->sections[ts->nsections].type = rec->type;
		ts->nsections++;
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

ssize_t
snapshot_and_decode(struct hwt_ctx *ctx, struct trace_state *ts,
    const char *pt_output, enum bsdtrace_fmt fmt)
{
	const uint8_t *buf;
	struct decode_probe_result base_probe, scan_probe;
	bool use_scan;
	size_t actual_len, known_end, record_len, scan_end, scan_limit, stop_len;
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
	use_scan = stop_len == 0 ||
	    (record_len > 0 && stop_len < record_len);
	known_end = use_scan ? record_len : stop_len;
	if (known_end == 0) {
		warnx("PT buffer is empty");
		return (0);
	}

	buf = hwt_ctx_map_buffer(ctx);
	if (buf == NULL)
		return (-1);

	actual_len = known_end;
	if (use_scan) {
		scan_limit = known_end + 16 * PAGE_SIZE;
		if (scan_limit > ctx->bufsize)
			scan_limit = ctx->bufsize;

		scan_end = scan_limit;
		while (scan_end > known_end && buf[scan_end - 1] == 0)
			scan_end--;
		if (scan_end < known_end)
			scan_end = known_end;
		actual_len = scan_end;
	} else if (record_len == 0 && stop_len > 0 && stop_len < PAGE_SIZE) {
		/*
		 * A tiny stop pointer with no BUFFER records often means the
		 * kernel lost the ToPA page index and reported only the
		 * within-page offset.  Probe a bounded look-ahead window, but
		 * only trust it if it decodes to more instructions and maps
		 * back to the current run's executable images.
		 */
		scan_limit = known_end + 16 * PAGE_SIZE;
		if (scan_limit > ctx->bufsize)
			scan_limit = ctx->bufsize;

		scan_end = scan_limit;
		while (scan_end > known_end && buf[scan_end - 1] == 0)
			scan_end--;
		if (scan_end < known_end)
			scan_end = known_end;

		memset(&base_probe, 0, sizeof(base_probe));
		memset(&scan_probe, 0, sizeof(scan_probe));
		(void)decode_pt_probe(buf, known_end,
		    ts->sections, ts->nsections, &base_probe);
		(void)decode_pt_probe(buf, scan_end,
		    ts->sections, ts->nsections, &scan_probe);

		if (scan_end > known_end &&
		    scan_probe.total > base_probe.total &&
		    scan_probe.exec_hits > base_probe.exec_hits)
			actual_len = scan_end;
	}

	saved = hwt_ctx_snapshot_buffer(ctx, pt_output,
	    (int)(actual_len / PAGE_SIZE),
	    actual_len % PAGE_SIZE);
	if (saved > 0) {
		fprintf(stderr,
		    "Saved %zd bytes of PT data to %s\n",
		    saved, pt_output);
		decode_pt_insn(buf, (size_t)saved,
		    ts->sections, ts->nsections, fmt);
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
	else
		fmt_record_text(rec, pid);

	if (pause_on_mmap &&
	    (rec->type == HWT_RECORD_MMAP ||
	     rec->type == HWT_RECORD_EXECUTABLE))
		hwt_ctx_wakeup(ctx);

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
 * Final drain, stop, snapshot, wrap warning, and cleanup.
 * Called at the end of both cmd_exec and cmd_trace.
 */
int
trace_finalize(struct hwt_ctx *ctx, struct trace_state *ts,
    struct meta_writer *meta, const char *pt_output, pid_t pid,
    enum bsdtrace_fmt fmt, int totalrecords)
{
	struct bsdtrace_record records[POLL_RECORDS];
	int nrecs, i;

	/* One final drain before stopping. */
	nrecs = 0;
	if (hwt_ctx_poll_records(ctx, records, POLL_RECORDS,
	    false, &nrecs) == 0) {
		for (i = 0; i < nrecs; i++) {
			totalrecords++;
			emit_and_process(&records[i], pid, fmt,
			    false, ctx, ts);
		}
	}

	hwt_ctx_stop(ctx);
	totalrecords += trace_state_drain_post_stop(ctx, ts);

	snapshot_and_decode(ctx, ts, pt_output, fmt);

	if (ts->buf_wrapped)
		fprintf(stderr,
		    "warning: PT buffer wrapped (data lost) — "
		    "increase with -s\n");

	hwt_ctx_close(ctx);
	meta_writer_close(meta);
	trace_state_free(ts);

	return (totalrecords);
}
