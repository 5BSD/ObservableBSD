/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace — process tracing via FreeBSD Hardware Trace (HWT).
 *
 * Shared header: types, prototypes, and the PT backend config struct
 * (which is not installed as a public kernel header).
 */

#ifndef BSDTRACE_H
#define BSDTRACE_H

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
 * RTIT_CTL bits used by bsdtrace.
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
#ifndef RTIT_CTL_ADDR_CFG_S
#define	RTIT_CTL_ADDR_CFG_S(n)	(32 + (n) * 4)
#endif

/* ------------------------------------------------------------------ */

/* Output format. */
enum bsdtrace_fmt {
	FMT_TEXT,
	FMT_JSON,
	FMT_PROFILE
};

/*
 * Parsed HWT record — mirrors the kernel's hwt_record_user_entry
 * but flattened so callers don't need to navigate the union.
 */
struct bsdtrace_record {
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
/*
 * IP range filter for hardware-level filtering.
 * Up to 2 ranges supported by Intel PT (ADDR0, ADDR1).
 */
struct ip_filter {
	int		nranges;
	struct {
		uint64_t	start;
		uint64_t	end;
	} ranges[2];
};

/*
 * Range specification — parsed from -r, either a hex address range
 * or a function name to resolve from ELF symbols.
 */
#define	RANGE_SPEC_SYMLEN	256

enum range_spec_type {
	RANGE_ADDR,
	RANGE_SYMBOL
};

struct range_spec {
	enum range_spec_type	type;
	uint64_t		start;		/* RANGE_ADDR only */
	uint64_t		end;		/* RANGE_ADDR only */
	char			symbol[RANGE_SPEC_SYMLEN]; /* RANGE_SYMBOL */
};

struct hwt_ctx {
	int		ctl_fd;		/* /dev/hwt                       */
	int		ctx_fd;		/* /dev/hwt_<ident>_<tid>         */
	int		kq_fd;		/* kqueue for event notification   */
	int		ident;		/* kernel-assigned context ident   */
	int		mode;		/* HWT_MODE_THREAD or _CPU        */
	int		tid;		/* thread index (default 0)       */
	pid_t		pid;		/* target PID (thread mode)       */
	char		backend_name[HWT_BACKEND_MAXNAMELEN];
	size_t		bufsize;	/* trace buffer size in bytes     */
	void		*trace_buf;	/* mmap'd trace buffer, or NULL   */
	struct ip_filter filter;	/* hardware IP range filter       */
};

/* ------------------------------------------------------------------ */
/* hwt.c — HWT context management                                     */
/* ------------------------------------------------------------------ */

int	 hwt_available(void);
int	 hwt_hooks_enabled(void);
char	*hwt_detect_backend(void);

int	 hwt_ctx_alloc(struct hwt_ctx *ctx, int mode, pid_t pid,
	    int tid, size_t bufsize, const char *backend);
int	 hwt_ctx_set_config(struct hwt_ctx *ctx, bool pause_on_mmap);
int	 hwt_ctx_start(struct hwt_ctx *ctx);
int	 hwt_ctx_stop(struct hwt_ctx *ctx);
int	 hwt_ctx_poll_records(struct hwt_ctx *ctx,
	    struct bsdtrace_record *records, int maxrecords,
	    bool wait, int *nout);
int	 hwt_ctx_wakeup(struct hwt_ctx *ctx);
void	*hwt_ctx_map_buffer(struct hwt_ctx *ctx);
int	 hwt_ctx_bufptr_get(struct hwt_ctx *ctx, int *page_out,
	    vm_offset_t *offset_out);
ssize_t	 hwt_ctx_snapshot_buffer(struct hwt_ctx *ctx, const char *path,
	    int last_page, vm_offset_t last_offset);
void	 hwt_ctx_close(struct hwt_ctx *ctx);

/* ------------------------------------------------------------------ */
/* Shared types                                                        */
/* ------------------------------------------------------------------ */

/*
 * Binary image section collected from EXEC / MMAP HWT records.
 */
struct pt_image_info {
	char		path[MAXPATHLEN];
	uint64_t	load_addr;	/* addr from EXEC/MMAP record */
	uint64_t	base_addr;	/* baseaddr (interp base for EXEC) */
	int		type;		/* HWT_RECORD_EXECUTABLE or _MMAP */
};

/*
 * Symbol table — maps runtime addresses to function names.
 */
struct sym_entry {
	uint64_t	addr;		/* runtime virtual address */
	uint64_t	size;		/* symbol size (0 if unknown) */
	char		*name;		/* function name (strdup'd) */
	char		*binary;	/* binary basename (strdup'd) */
};

struct sym_table {
	struct sym_entry	*entries;
	int			count;
	int			capacity;
};

/*
 * Binary load range — for showing binary+offset when no symbol matches.
 */
#define	MAX_BIN_RANGES	256

struct bin_range {
	char		name[64];	/* basename of binary */
	uint64_t	lo;		/* lowest runtime text address */
	uint64_t	hi;		/* highest runtime text address */
	uint64_t	base;		/* load base (slide origin) */
};

/*
 * Per-trace accumulator — tracks image sections, buffer state, and
 * metadata across the polling loop.
 */
struct trace_state {
	struct pt_image_info	*sections;
	int			nsections;
	int			sections_cap;
	struct meta_writer	*meta;
	int			last_buf_page;
	int			max_buf_page;
	vm_offset_t		last_buf_offset;
	bool			buf_wrapped;
};

struct decode_probe_result {
	int	total;
	int	exec_hits;
};

/* ------------------------------------------------------------------ */
/* format.c — output formatting                                        */
/* ------------------------------------------------------------------ */

void	 fmt_record_text(const struct bsdtrace_record *rec, pid_t pid);
void	 fmt_record_json(const struct bsdtrace_record *rec, pid_t pid);
int	 json_escape(char *dst, size_t dstlen, const char *src);

/* ------------------------------------------------------------------ */
/* elf.c — ELF parsing                                                 */
/* ------------------------------------------------------------------ */

struct pt_image;	/* forward decl (libipt) */
struct _Elf;		/* forward decl (libelf) */
typedef struct _Elf Elf;

bool	 is_user_addr(uint64_t addr);
int	 elf_base_vaddr(Elf *elf, uint64_t *base_out);
int	 elf_exec_map_vaddr(Elf *elf, uint64_t *exec_out);
int	 elf_preferred_symtab_type(Elf *elf);
int	 elf_effective_load_addr(Elf *elf, int type, uint64_t record_addr,
	    uint64_t *load_out);
bool	 section_should_use(const struct pt_image_info *sections, int nsections,
	    int idx);
int	 add_elf_to_image(struct pt_image *image, const char *path,
	    uint64_t load_addr);
int	 elf_get_interp(const char *path, char *interp, size_t interpsz);
int	 build_bin_ranges(const struct pt_image_info *sections, int nsections,
	    struct bin_range *ranges, int maxranges);
const char *find_binary_for_ip(const struct bin_range *ranges, int nranges,
	    uint64_t ip, uint64_t *offset);

/* ------------------------------------------------------------------ */
/* symbols.c — symbol table                                            */
/* ------------------------------------------------------------------ */

void	 sym_table_init(struct sym_table *st);
void	 sym_table_add(struct sym_table *st, uint64_t addr, uint64_t size,
	    const char *name, const char *binary);
void	 sym_table_add_elf(struct sym_table *st, const char *path,
	    int64_t slide);
void	 sym_table_sort(struct sym_table *st);
const struct sym_entry *sym_table_lookup(const struct sym_table *st,
	    uint64_t ip);
void	 sym_table_free(struct sym_table *st);

/* ------------------------------------------------------------------ */
/* resolve.c — symbol-to-address range resolution                      */
/* ------------------------------------------------------------------ */

int	 parse_range_spec(const char *arg, struct range_spec *spec);
int	 resolve_symbol_in_elf(const char *path, int64_t slide,
	    const char *name, uint64_t *start_out, uint64_t *end_out);
int	 process_exe_fullpath(pid_t pid, char *buf, size_t bufsz);
int	 process_load_addr(pid_t pid, const char *exe_path,
	    uint64_t *load_out);
int	 elf_is_pie(const char *path);
int	 resolve_range_specs(struct range_spec *specs, int nspecs,
	    struct ip_filter *filter, pid_t pid, const char *exe_path,
	    bool is_exec_mode, bool *aslr_disable);

/* ------------------------------------------------------------------ */
/* decode.c — PT packet / instruction decoder                          */
/* ------------------------------------------------------------------ */

int	 decode_pt_buffer(const void *buf, size_t len, enum bsdtrace_fmt fmt);
int	 decode_pt_insn(const void *buf, size_t len,
	    const struct pt_image_info *sections, int nsections,
	    enum bsdtrace_fmt fmt, int tid);
int	 decode_pt_probe(const void *buf, size_t len,
	    const struct pt_image_info *sections, int nsections,
	    struct decode_probe_result *result);

/* ------------------------------------------------------------------ */
/* meta.c — .meta sidecar writer/reader                                */
/* ------------------------------------------------------------------ */

struct meta_writer;

struct meta_writer *meta_writer_open(const char *path);
void	 meta_writer_header(struct meta_writer *mw, pid_t pid, int tid);
void	 meta_writer_record(struct meta_writer *mw,
	    const struct bsdtrace_record *rec);
void	 meta_writer_close(struct meta_writer *mw);
int	 meta_read_tid(const char *path);
int	 meta_read_sections(const char *path,
	    struct pt_image_info **sections_out, int *nsections_out);

/* ------------------------------------------------------------------ */
/* trace.c — trace state and shared helpers                            */
/* ------------------------------------------------------------------ */

void	 trace_state_init(struct trace_state *ts, struct meta_writer *meta);
void	 trace_state_process(struct trace_state *ts,
	    const struct bsdtrace_record *rec);
int	 trace_state_drain_post_stop(struct hwt_ctx *ctx,
	    struct trace_state *ts);
void	 trace_state_free(struct trace_state *ts);
ssize_t	 snapshot_and_decode(struct hwt_ctx *ctx, struct trace_state *ts,
	    const char *pt_output, enum bsdtrace_fmt fmt, int tid);

void	 emit_and_process(const struct bsdtrace_record *rec, pid_t pid,
	    enum bsdtrace_fmt fmt, bool pause_on_mmap, struct hwt_ctx *ctx,
	    struct trace_state *ts);
const char *resolve_backend(const char *explicit_name, char **detected_out,
	    bool dryrun);
int	 check_hwt_hooks(bool dryrun);
void	 derive_meta_path(const char *pt_output, char *meta_path,
	    size_t meta_pathsz);
int	 trace_finalize(struct hwt_ctx *ctx, struct trace_state *ts,
	    struct meta_writer *meta, const char *pt_output, pid_t pid,
	    enum bsdtrace_fmt fmt, int totalrecords);

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

int	 cmd_list(int argc, char **argv);
int	 cmd_exec(int argc, char **argv);
int	 cmd_trace(int argc, char **argv);
int	 cmd_decode(int argc, char **argv);

/* ------------------------------------------------------------------ */
/* bsdtrace.c — shared helpers                                         */
/* ------------------------------------------------------------------ */

size_t	 parse_size(const char *s);
const char *process_name(pid_t pid, char *buf, size_t bufsz);

#endif /* !BSDTRACE_H */
