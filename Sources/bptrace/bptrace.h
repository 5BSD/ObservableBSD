/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bptrace — process tracing via FreeBSD Hardware Trace (HWT).
 *
 * Shared header: types, prototypes, and the PT backend config struct
 * (which is not installed as a public kernel header).
 */

#ifndef BPTRACE_H
#define BPTRACE_H

#include <sys/types.h>
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/hwt.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * PT backend per-CPU configuration.
 *
 * Copied from <amd64/pt/pt.h> which is NOT installed as a public
 * header.  This struct is passed to the kernel via HWT_IOC_SET_CONFIG;
 * the kernel stores it in ctx->config and later casts it back to
 * (struct pt_cpu_config *) in pt_backend_configure().
 *
 * If ctx->config is NULL when the traced thread is scheduled in,
 * the kernel will page-fault (NULL deref) — this was the cause of
 * the vmcore.4 panic.
 *
 * Guard: if someone compiles with -I/usr/src/sys and the real
 * pt.h gets included first, its include guard skips our copy.
 */
#ifndef _AMD64_PT_PT_H_
#define	PT_IP_FILTER_MAX_RANGES	2

struct pt_cpu_config {
	uint64_t	rtit_ctl;
	register_t	cr3_filter;
	int		nranges;
	struct {
		vm_offset_t	start;
		vm_offset_t	end;
	} ip_ranges[PT_IP_FILTER_MAX_RANGES];
	uint32_t	mtc_freq;
	uint32_t	cyc_thresh;
	uint32_t	psb_freq;
};
#endif /* !_AMD64_PT_PT_H_ */

#ifdef __amd64__
_Static_assert(sizeof(struct pt_cpu_config) == 72,
    "pt_cpu_config size drifted from amd64/pt/pt.h");
_Static_assert(offsetof(struct pt_cpu_config, cr3_filter) == 8,
    "pt_cpu_config.cr3_filter offset mismatch");
_Static_assert(offsetof(struct pt_cpu_config, nranges) == 16,
    "pt_cpu_config.nranges offset mismatch");
_Static_assert(offsetof(struct pt_cpu_config, ip_ranges) == 24,
    "pt_cpu_config.ip_ranges offset mismatch");
_Static_assert(offsetof(struct pt_cpu_config, mtc_freq) == 56,
    "pt_cpu_config.mtc_freq offset mismatch");
_Static_assert(offsetof(struct pt_cpu_config, cyc_thresh) == 60,
    "pt_cpu_config.cyc_thresh offset mismatch");
_Static_assert(offsetof(struct pt_cpu_config, psb_freq) == 64,
    "pt_cpu_config.psb_freq offset mismatch");
#endif

_Static_assert(sizeof(struct hwt_alloc) == 64 && _Alignof(struct hwt_alloc) == 16,
    "hwt_alloc ABI mismatch");
_Static_assert(sizeof(struct hwt_start) == 16 && _Alignof(struct hwt_start) == 16,
    "hwt_start ABI mismatch");
_Static_assert(sizeof(struct hwt_stop) == 16 && _Alignof(struct hwt_stop) == 16,
    "hwt_stop ABI mismatch");
_Static_assert(sizeof(struct hwt_record_get) == 32 &&
    _Alignof(struct hwt_record_get) == 16,
    "hwt_record_get ABI mismatch");
_Static_assert(sizeof(struct hwt_set_config) == 32 &&
    _Alignof(struct hwt_set_config) == 16,
    "hwt_set_config ABI mismatch");
_Static_assert(sizeof(struct hwt_wakeup) == 16 &&
    _Alignof(struct hwt_wakeup) == 16,
    "hwt_wakeup ABI mismatch");

/*
 * RTIT_CTL bits used by bptrace.
 *
 * Defined in <x86/specialreg.h> but guarded here in case that
 * header is unavailable on non-x86 builds.
 */
#ifndef RTIT_CTL_USER
#define	RTIT_CTL_USER		(1 << 3)
#endif
#ifndef RTIT_CTL_BRANCHEN
#define	RTIT_CTL_BRANCHEN	(1 << 13)
#endif

/* ------------------------------------------------------------------ */

/* Output format. */
enum bptrace_fmt {
	FMT_TEXT,
	FMT_JSON
};

/*
 * Parsed HWT record — mirrors the kernel's hwt_record_user_entry
 * but flattened so callers don't need to navigate the union.
 */
struct bptrace_record {
	enum hwt_record_type	type;
	char			fullpath[MAXPATHLEN];
	uintptr_t		addr;
	uintptr_t		baseaddr;
	int			buf_id;
	int			curpage;
	vm_offset_t		offset;
	int			thread_id;
};

/*
 * HWT context handle — owns the file descriptors and state for one
 * tracing session.
 *
 * Lifecycle: alloc → set_config → start → poll/map → stop → close
 */
struct hwt_ctx {
	int		ctl_fd;		/* /dev/hwt                       */
	int		ctx_fd;		/* /dev/hwt_<ident>_0             */
	int		kq_fd;		/* kqueue for event notification   */
	int		ident;		/* kernel-assigned context ident   */
	int		mode;		/* HWT_MODE_THREAD or _CPU        */
	pid_t		pid;		/* target PID (thread mode)       */
	char		backend_name[HWT_BACKEND_MAXNAMELEN];
	size_t		bufsize;	/* trace buffer size in bytes     */
	void		*trace_buf;	/* mmap'd trace buffer, or NULL   */
};

/* ------------------------------------------------------------------ */
/* hwt.c — HWT context management                                     */
/* ------------------------------------------------------------------ */

int	 hwt_available(void);
char	*hwt_detect_backend(void);

int	 hwt_ctx_alloc(struct hwt_ctx *ctx, int mode, pid_t pid,
	    size_t bufsize, const char *backend);
int	 hwt_ctx_set_config(struct hwt_ctx *ctx, bool pause_on_mmap);
int	 hwt_ctx_start(struct hwt_ctx *ctx);
int	 hwt_ctx_stop(struct hwt_ctx *ctx);
int	 hwt_ctx_poll_records(struct hwt_ctx *ctx,
	    struct bptrace_record *records, int maxrecords,
	    bool wait, int *nout);
int	 hwt_ctx_wakeup(struct hwt_ctx *ctx);
void	*hwt_ctx_map_buffer(struct hwt_ctx *ctx);
void	 hwt_ctx_close(struct hwt_ctx *ctx);

/* ------------------------------------------------------------------ */
/* format.c — output formatting                                        */
/* ------------------------------------------------------------------ */

void	 fmt_record_text(const struct bptrace_record *rec, pid_t pid);
void	 fmt_record_json(const struct bptrace_record *rec, pid_t pid);

/* ------------------------------------------------------------------ */
/* cmd_list.c / cmd_exec.c / cmd_trace.c                               */
/* ------------------------------------------------------------------ */

int	 cmd_list(int argc, char **argv);
int	 cmd_exec(int argc, char **argv);
int	 cmd_trace(int argc, char **argv);

/* ------------------------------------------------------------------ */
/* Shared helpers (bptrace.c)                                          */
/* ------------------------------------------------------------------ */

size_t	 parse_size(const char *s);
const char *process_name(pid_t pid, char *buf, size_t bufsz);

#endif /* !BPTRACE_H */
