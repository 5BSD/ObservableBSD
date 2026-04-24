/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * HWT context management — wraps the FreeBSD hwt(4) ioctl interface.
 *
 * Every struct passed to ioctl(2) is defined in <sys/hwt.h> with
 * __aligned(16).  Since this is plain C compiled with the same
 * toolchain as the kernel, the struct layouts match exactly — no
 * bridging or alignment guessing required.
 *
 * Key correctness notes (from the kernel source):
 *
 *   - hwt_alloc.ident and hwt_alloc.backend_name are userspace
 *     pointers.  The kernel uses copyout()/copyinstr() on them.
 *
 *   - hwt_record_get.nentries is a pointer to int.  The kernel
 *     copyin()s the requested count and copyout()s the actual count.
 *
 *   - hwt_set_config.config is a userspace pointer to the backend
 *     config struct.  The kernel copyin()s config_size bytes.
 *
 *   - HWT_IOC_SET_CONFIG MUST be called before HWT_IOC_START.
 *     The PT backend dereferences ctx->config on the first
 *     hwt_switch_in — if it's NULL, the kernel page-faults.
 */

#include <sys/types.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/linker.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/hwt.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bptrace.h"

/* ------------------------------------------------------------------ */
/* Detection                                                           */
/* ------------------------------------------------------------------ */

int
hwt_available(void)
{
	int fd;

	fd = open("/dev/hwt", O_RDWR);
	if (fd < 0)
		return (0);
	close(fd);
	return (1);
}

int
hwt_hooks_enabled(void)
{
	char *conftxt;
	size_t len;
	int enabled;

	len = 0;
	if (sysctlbyname("kern.conftxt", NULL, &len, NULL, 0) != 0)
		return (-1);
	if (len == 0)
		return (-1);

	conftxt = calloc(1, len + 1);
	if (conftxt == NULL)
		return (-1);

	if (sysctlbyname("kern.conftxt", conftxt, &len, NULL, 0) != 0) {
		free(conftxt);
		return (-1);
	}

	enabled = strstr(conftxt, "options\tHWT_HOOKS") != NULL;
	free(conftxt);
	return (enabled ? 1 : 0);
}

char *
hwt_detect_backend(void)
{
	static const char *backends[] = { "pt", "coresight", "spe" };
	size_t i;

	for (i = 0; i < nitems(backends); i++) {
		if (kldfind(backends[i]) != -1)
			return (strdup(backends[i]));
	}
	return (NULL);
}

/* ------------------------------------------------------------------ */
/* Context allocation                                                  */
/* ------------------------------------------------------------------ */

int
hwt_ctx_alloc(struct hwt_ctx *ctx, int mode, pid_t pid,
    int tid, size_t bufsize, const char *backend)
{
	struct hwt_alloc ha;
	char devpath[64];
	int ident;

	memset(ctx, 0, sizeof(*ctx));
	ctx->ctl_fd = -1;
	ctx->ctx_fd = -1;
	ctx->kq_fd = -1;
	ctx->mode = mode;
	ctx->tid = tid;
	ctx->pid = pid;

	if (backend == NULL || backend[0] == '\0') {
		warnx("empty HWT backend name");
		errno = EINVAL;
		return (-1);
	}
	if (strlcpy(ctx->backend_name, backend, sizeof(ctx->backend_name)) >=
	    sizeof(ctx->backend_name)) {
		warnx("HWT backend name too long: %s", backend);
		errno = ENAMETOOLONG;
		return (-1);
	}

	/*
	 * The kernel requires bufsize to be a multiple of PAGE_SIZE
	 * (hwt_ioctl.c returns EINVAL otherwise).  Round up.
	 */
	if (bufsize == 0)
		bufsize = 64 * 1024 * 1024;
	bufsize = (bufsize + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
	ctx->bufsize = bufsize;

	/* Open /dev/hwt control device. */
	ctx->ctl_fd = open("/dev/hwt", O_RDWR);
	if (ctx->ctl_fd < 0) {
		warn("open /dev/hwt");
		return (-1);
	}

	/* Create kqueue for event notification. */
	ctx->kq_fd = kqueue();
	if (ctx->kq_fd < 0) {
		warn("kqueue");
		goto fail;
	}

	/*
	 * Allocate HWT context via ioctl.
	 *
	 * The hwt_alloc struct is __aligned(16).  All pointer fields
	 * (ident, backend_name, cpu_map) are userspace addresses that
	 * the kernel accesses via copyin/copyout/copyinstr.
	 *
	 * Kernel constraints (from hwt_ioctl.c):
	 *   - bufsize must be <= 32 GB and page-aligned
	 *   - backend_name must not be NULL
	 *   - mode must be HWT_MODE_THREAD or HWT_MODE_CPU
	 */
	ident = 0;
	memset(&ha, 0, sizeof(ha));
	ha.bufsize = bufsize;
	ha.mode = mode;
	ha.pid = pid;
	ha.cpu_map = NULL;
	ha.cpusetsize = 0;
	ha.backend_name = ctx->backend_name;
	ha.ident = &ident;
	ha.kqueue_fd = ctx->kq_fd;

	if (ioctl(ctx->ctl_fd, HWT_IOC_ALLOC, &ha) != 0) {
		warn("HWT_IOC_ALLOC (backend=%s, pid=%d, bufsize=%zu)",
		    backend, (int)pid, bufsize);
		goto fail;
	}
	ctx->ident = ident;

	/*
	 * Open the per-context character device.
	 *
	 * In thread mode the kernel names devices hwt_<ident>_<counter>
	 * starting at 0 (the main thread).  In CPU mode the suffix is
	 * the cpu_id.  We always open thread/cpu 0.
	 */
	snprintf(devpath, sizeof(devpath), "/dev/hwt_%d_%d",
	    ctx->ident, ctx->tid);
	ctx->ctx_fd = open(devpath, O_RDWR);
	if (ctx->ctx_fd < 0) {
		warn("open %s", devpath);
		goto fail;
	}

	return (0);

fail:
	hwt_ctx_close(ctx);
	return (-1);
}

/* ------------------------------------------------------------------ */
/* Configuration                                                       */
/* ------------------------------------------------------------------ */

static int
hwt_ctx_set_config_pt(struct hwt_ctx *ctx, bool pause_on_mmap)
{
	struct hwt_set_config sc;
	struct pt_cpu_config ptcfg;

	/*
	 * Build the PT backend configuration.
	 *
	 * The kernel's pt_backend_configure() (pt.c) casts ctx->config
	 * to (struct pt_cpu_config *) and immediately dereferences it:
	 *
	 *   cfg = (struct pt_cpu_config *)ctx->config;
	 *   cfg->rtit_ctl &= PT_SUPPORTED_FLAGS;
	 *
	 * If ctx->config is NULL (SET_CONFIG never called, or failed),
	 * this is a kernel page fault.  This was the vmcore.4 crash.
	 *
	 * Minimum viable config: user-mode branch tracing.
	 *   RTIT_CTL_USER    (bit 3)  — trace user-mode only
	 *   RTIT_CTL_BRANCHEN (bit 13) — enable branch tracing
	 *
	 * The PT backend adds RTIT_CTL_TOPA and RTIT_CTL_TRACEEN itself.
	 */
	memset(&ptcfg, 0, sizeof(ptcfg));
	ptcfg.rtit_ctl = RTIT_CTL_USER | RTIT_CTL_BRANCHEN;
	ptcfg.nranges = 0;

	/*
	 * Fill the hwt_set_config struct (__aligned(16)).
	 *
	 * sc.config is a userspace pointer.  The kernel's hwt_config_set()
	 * does:
	 *   config = malloc(config_size, ...);
	 *   copyin(sconf->config, config, config_size);
	 *   ctx->config = config;
	 *
	 * So config_size MUST equal sizeof(struct pt_cpu_config) as the
	 * kernel compiled it.  Since we use the identical struct definition
	 * and the same compiler, sizeof matches.
	 */
	memset(&sc, 0, sizeof(sc));
	sc.pause_on_mmap = pause_on_mmap ? 1 : 0;
	sc.config = &ptcfg;
	sc.config_size = sizeof(ptcfg);
	sc.config_version = 0;

	if (ioctl(ctx->ctx_fd, HWT_IOC_SET_CONFIG, &sc) != 0) {
		warn("HWT_IOC_SET_CONFIG");
		return (-1);
	}

	return (0);
}

int
hwt_ctx_set_config(struct hwt_ctx *ctx, bool pause_on_mmap)
{

	if (ctx->backend_name[0] == '\0') {
		warnx("HWT backend name missing from context");
		errno = EINVAL;
		return (-1);
	}

	if (strcmp(ctx->backend_name, "pt") == 0)
		return (hwt_ctx_set_config_pt(ctx, pause_on_mmap));

	warnx("unsupported HWT backend '%s': refusing to send Intel PT config "
	    "bytes to a non-PT backend", ctx->backend_name);
	errno = EOPNOTSUPP;
	return (-1);
}

/* ------------------------------------------------------------------ */
/* Start / Stop                                                        */
/* ------------------------------------------------------------------ */

int
hwt_ctx_start(struct hwt_ctx *ctx)
{
	struct hwt_start hs;

	memset(&hs, 0, sizeof(hs));
	if (ioctl(ctx->ctx_fd, HWT_IOC_START, &hs) != 0) {
		warn("HWT_IOC_START");
		return (-1);
	}
	return (0);
}

int
hwt_ctx_stop(struct hwt_ctx *ctx)
{

	/*
	 * Do NOT issue HWT_IOC_STOP.
	 *
	 * The PT backend in the kernel does not implement the
	 * hwt_backend_stop() op — the function pointer is NULL.
	 * Calling HWT_IOC_STOP triggers hwt_backend_stop() which
	 * dereferences the NULL pointer and panics the kernel.
	 *
	 * Workaround: close the context fd instead.  The kernel's
	 * context teardown path calls hwt_backend_deinit(), which
	 * the PT backend *does* implement (pt_backend_deinit stops
	 * tracing on all active CPUs and frees ToPA metadata).
	 *
	 * Closing ctx_fd here also prevents the subsequent
	 * hwt_ctx_close() from double-closing the fd.
	 */
	if (ctx->ctx_fd >= 0) {
		close(ctx->ctx_fd);
		ctx->ctx_fd = -1;
	}
	return (0);
}

/* ------------------------------------------------------------------ */
/* Record polling                                                      */
/* ------------------------------------------------------------------ */

int
hwt_ctx_poll_records(struct hwt_ctx *ctx,
    struct bptrace_record *records, int maxrecords,
    bool wait, int *nout)
{
	struct hwt_record_user_entry *entries;
	struct hwt_record_get rg;
	int nentries;
	int i;

	/*
	 * hwt_ctx_stop() closes ctx_fd to avoid the PT backend's
	 * broken HWT_IOC_STOP path. Treat post-stop polling as an
	 * empty drain rather than surfacing EBADF to the caller.
	 */
	if (ctx->ctx_fd < 0) {
		if (nout != NULL)
			*nout = 0;
		return (0);
	}

	/*
	 * The kernel limits nentries to 1024 (hwt_record.c:258).
	 * Clamp our request to avoid ENXIO.
	 */
	if (maxrecords > 1024)
		maxrecords = 1024;

	entries = calloc(maxrecords, sizeof(*entries));
	if (entries == NULL) {
		warn("calloc");
		return (-1);
	}

	/*
	 * hwt_record_get is __aligned(16).
	 *
	 * rg.records — userspace buffer for the kernel to copyout into.
	 * rg.nentries — pointer to int; kernel copyin()s the request
	 *               count, then copyout()s the actual count.
	 * rg.wait — if non-zero, kernel sleeps until records arrive.
	 */
	nentries = maxrecords;
	memset(&rg, 0, sizeof(rg));
	rg.records = entries;
	rg.nentries = &nentries;
	rg.wait = wait ? 1 : 0;

	if (ioctl(ctx->ctx_fd, HWT_IOC_RECORD_GET, &rg) != 0) {
		warn("HWT_IOC_RECORD_GET");
		free(entries);
		return (-1);
	}

	/*
	 * Convert kernel union entries to our flat struct.
	 *
	 * The hwt_record_user_entry union layout (from sys/hwt.h):
	 *   - MMAP/EXECUTABLE/KERNEL: fullpath[], addr, baseaddr
	 *   - BUFFER: buf_id, curpage, offset
	 *   - THREAD_CREATE/THREAD_SET_NAME: thread_id
	 *
	 * The kernel's hwt_record_to_user() (hwt_record.c:85) populates
	 * only the fields relevant to each record_type.
	 */
	for (i = 0; i < nentries; i++) {
		struct hwt_record_user_entry *e = &entries[i];
		struct bptrace_record *r = &records[i];

		memset(r, 0, sizeof(*r));
		r->type = e->record_type;

		switch (e->record_type) {
		case HWT_RECORD_MMAP:
		case HWT_RECORD_EXECUTABLE:
		case HWT_RECORD_KERNEL:
			strlcpy(r->fullpath, e->fullpath,
			    sizeof(r->fullpath));
			r->addr = e->addr;
			r->baseaddr = e->baseaddr;
			break;
		case HWT_RECORD_MUNMAP:
			r->addr = e->addr;
			break;
		case HWT_RECORD_BUFFER:
			r->buf_id = e->buf_id;
			r->curpage = e->curpage;
			r->offset = e->offset;
			break;
		case HWT_RECORD_THREAD_CREATE:
		case HWT_RECORD_THREAD_SET_NAME:
			r->thread_id = e->thread_id;
			break;
		default:
			break;
		}
	}

	free(entries);
	*nout = nentries;
	return (0);
}

/* ------------------------------------------------------------------ */
/* Wakeup (for pause-on-mmap)                                          */
/* ------------------------------------------------------------------ */

int
hwt_ctx_wakeup(struct hwt_ctx *ctx)
{
	struct hwt_wakeup hw;

	memset(&hw, 0, sizeof(hw));
	if (ioctl(ctx->ctx_fd, HWT_IOC_WAKEUP, &hw) != 0) {
		warn("HWT_IOC_WAKEUP");
		return (-1);
	}
	return (0);
}

/* ------------------------------------------------------------------ */
/* Buffer mmap                                                         */
/* ------------------------------------------------------------------ */

void *
hwt_ctx_map_buffer(struct hwt_ctx *ctx)
{
	void *ptr;

	if (ctx->trace_buf != NULL)
		return (ctx->trace_buf);

	ptr = mmap(NULL, ctx->bufsize, PROT_READ, MAP_SHARED,
	    ctx->ctx_fd, 0);
	if (ptr == MAP_FAILED) {
		warn("mmap trace buffer");
		return (NULL);
	}
	ctx->trace_buf = ptr;
	return (ptr);
}

/* ------------------------------------------------------------------ */
/* Buffer snapshot                                                     */
/* ------------------------------------------------------------------ */

ssize_t
hwt_ctx_snapshot_buffer(struct hwt_ctx *ctx, const char *path,
    int last_page, vm_offset_t last_offset)
{
	const uint8_t *buf;
	size_t total;
	ssize_t nw;
	size_t off;
	int fd;

	if (last_page < 0) {
		warnx("no BUFFER records seen — nothing to snapshot");
		return (0);
	}

	buf = hwt_ctx_map_buffer(ctx);
	if (buf == NULL)
		return (-1);

	total = (size_t)last_page * PAGE_SIZE + last_offset;
	if (total > ctx->bufsize)
		total = ctx->bufsize;
	if (total == 0) {
		warnx("PT buffer is empty (0 bytes)");
		return (0);
	}

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		warn("open %s", path);
		return (-1);
	}

	off = 0;
	while (off < total) {
		nw = write(fd, buf + off, total - off);
		if (nw < 0) {
			warn("write %s", path);
			close(fd);
			return (-1);
		}
		off += nw;
	}

	close(fd);
	return ((ssize_t)total);
}

/* ------------------------------------------------------------------ */
/* Cleanup                                                             */
/* ------------------------------------------------------------------ */

void
hwt_ctx_close(struct hwt_ctx *ctx)
{

	if (ctx->trace_buf != NULL) {
		munmap(ctx->trace_buf, ctx->bufsize);
		ctx->trace_buf = NULL;
	}
	if (ctx->ctx_fd >= 0) {
		close(ctx->ctx_fd);
		ctx->ctx_fd = -1;
	}
	if (ctx->kq_fd >= 0) {
		close(ctx->kq_fd);
		ctx->kq_fd = -1;
	}
	if (ctx->ctl_fd >= 0) {
		close(ctx->ctl_fd);
		ctx->ctl_fd = -1;
	}
}
