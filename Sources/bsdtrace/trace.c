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

#include "bsdtrace.h"

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

/* ------------------------------------------------------------------ */
/* Snapshot and decode — shared between cmd_exec and cmd_trace         */
/* ------------------------------------------------------------------ */

ssize_t
snapshot_and_decode(struct hwt_ctx *ctx, struct trace_state *ts,
    const char *pt_output, enum bsdtrace_fmt fmt)
{
	const uint8_t *buf;
	size_t actual_len;
	int actual_page;
	vm_offset_t actual_offset;
	ssize_t saved;

	if (ts->last_buf_page < 0)
		return (0);

	/*
	 * Map the trace buffer and find the actual extent of PT data.
	 *
	 * BUFFER records report the write pointer at the time each
	 * record is generated, but the CPU keeps writing PT data
	 * between records.  Short-lived programs often finish before
	 * a final BUFFER record is emitted, leaving their trace data
	 * beyond last_buf_page.
	 *
	 * Scan *forward* from the last known BUFFER position with a
	 * bounded look-ahead (up to 16 pages / 64 KB).  Scanning the
	 * entire buffer backwards would fault in every page of the
	 * mmaped kernel buffer while PT hardware is still active,
	 * greatly increasing the odds of hitting the pt.ko swi race
	 * (NULL deref in pt_send_buffer_record).
	 */
	buf = hwt_ctx_map_buffer(ctx);
	if (buf == NULL)
		return (-1);

	{
		size_t known_end;
		size_t scan_limit;

		known_end = (size_t)ts->last_buf_page * PAGE_SIZE +
		    ts->last_buf_offset;
		if (known_end > ctx->bufsize)
			known_end = ctx->bufsize;

		/* Look ahead up to 16 pages past the last BUFFER record. */
		scan_limit = known_end + 16 * PAGE_SIZE;
		if (scan_limit > ctx->bufsize)
			scan_limit = ctx->bufsize;

		/* Find the last non-zero byte in the look-ahead region only. */
		actual_len = scan_limit;
		while (actual_len > known_end && buf[actual_len - 1] == 0)
			actual_len--;

		/* Fall back to known extent if look-ahead is all zeros. */
		if (actual_len < known_end)
			actual_len = known_end;
	}

	if (actual_len == 0) {
		warnx("PT buffer is empty");
		return (0);
	}

	actual_page = (int)(actual_len / PAGE_SIZE);
	actual_offset = actual_len % PAGE_SIZE;

	saved = hwt_ctx_snapshot_buffer(ctx, pt_output,
	    actual_page, actual_offset);
	if (saved > 0) {
		fprintf(stderr,
		    "Saved %zd bytes of PT data to %s "
		    "(buf_record=%d, actual=%zu)\n",
		    saved, pt_output,
		    ts->last_buf_page, actual_len);
		decode_pt_insn(buf, (size_t)saved,
		    ts->sections, ts->nsections, fmt);
	}
	return (saved);
}
