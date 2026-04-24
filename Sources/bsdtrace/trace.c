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
/* Snapshot and decode — shared between cmd_exec and cmd_trace         */
/* ------------------------------------------------------------------ */

ssize_t
snapshot_and_decode(struct hwt_ctx *ctx, struct trace_state *ts,
    const char *pt_output, enum bsdtrace_fmt fmt)
{
	ssize_t saved;

	if (ts->last_buf_page < 0)
		return (0);

	saved = hwt_ctx_snapshot_buffer(ctx, pt_output,
	    ts->last_buf_page, ts->last_buf_offset);
	if (saved > 0) {
		fprintf(stderr,
		    "Saved %zd bytes of PT data to %s\n",
		    saved, pt_output);
		decode_pt_insn(ctx->trace_buf, (size_t)saved,
		    ts->sections, ts->nsections, fmt);
	}
	return (saved);
}
