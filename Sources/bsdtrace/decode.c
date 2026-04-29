/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * PT decoder — packet-level and instruction-level decoding via libipt.
 *
 * decode_pt_buffer() uses the packet decoder (pt_pkt_*) to dump raw
 * PT packets without needing a binary image.
 *
 * decode_pt_insn() uses the instruction decoder (pt_insn_*) with a
 * pt_image built from EXEC/MMAP records to decode actual control-flow
 * events (calls, returns, branches, syscalls).  ELF parsing and symbol
 * resolution are handled by elf.c and symbols.c.
 */

#include <sys/types.h>

#include <err.h>
#include <fcntl.h>
#include <gelf.h>
#include <libelf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <intel-pt.h>
#include <pt_cpu.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static const char *
exec_mode_str(enum pt_exec_mode mode)
{

	switch (mode) {
	case ptem_16bit:	return ("16-bit");
	case ptem_32bit:	return ("32-bit");
	case ptem_64bit:	return ("64-bit");
	default:		return ("unknown");
	}
}

static void
tnt_str(char *buf, size_t bufsz, uint64_t payload, uint8_t bit_size)
{
	int i;

	if ((size_t)bit_size >= bufsz)
		bit_size = (uint8_t)(bufsz - 1);

	for (i = bit_size - 1; i >= 0; i--)
		*buf++ = (payload & (1ULL << i)) ? '!' : '.';
	*buf = '\0';
}

/* ------------------------------------------------------------------ */
/* Packet-level text output                                            */
/* ------------------------------------------------------------------ */

static void
emit_packet_text(const struct pt_packet *pkt)
{
	char tnt[65];

	switch (pkt->type) {
	case ppt_psb:
		printf("  PSB\n");
		break;
	case ppt_psbend:
		printf("  PSBEND\n");
		break;
	case ppt_tip:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("  TIP       suppressed\n");
		else
			printf("  TIP       0x%016lx\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tip_pge:
		printf("  TIP.PGE   0x%016lx\n",
		    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tip_pgd:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("  TIP.PGD   suppressed\n");
		else
			printf("  TIP.PGD   0x%016lx\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_fup:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("  FUP       suppressed\n");
		else
			printf("  FUP       0x%016lx\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tnt_8:
	case ppt_tnt_64:
		tnt_str(tnt, sizeof(tnt), pkt->payload.tnt.payload,
		    pkt->payload.tnt.bit_size);
		printf("  TNT       %s\n", tnt);
		break;
	case ppt_mode:
		if (pkt->payload.mode.leaf == pt_mol_exec)
			printf("  MODE.Exec %s\n",
			    exec_mode_str(
			    pt_get_exec_mode(&pkt->payload.mode.bits.exec)));
		else if (pkt->payload.mode.leaf == pt_mol_tsx)
			printf("  MODE.TSX  intx=%d abrt=%d\n",
			    pkt->payload.mode.bits.tsx.intx,
			    pkt->payload.mode.bits.tsx.abrt);
		else
			printf("  MODE      leaf=0x%02x\n",
			    pkt->payload.mode.leaf);
		break;
	case ppt_pip:
		printf("  PIP       cr3=0x%016lx nr=%d\n",
		    (unsigned long)pkt->payload.pip.cr3,
		    pkt->payload.pip.nr);
		break;
	case ppt_tsc:
		printf("  TSC       0x%lx\n",
		    (unsigned long)pkt->payload.tsc.tsc);
		break;
	case ppt_cbr:
		printf("  CBR       ratio=%u\n", pkt->payload.cbr.ratio);
		break;
	case ppt_tma:
		printf("  TMA       ctc=0x%04x fc=0x%04x\n",
		    pkt->payload.tma.ctc, pkt->payload.tma.fc);
		break;
	case ppt_mtc:
		printf("  MTC       ctc=0x%02x\n", pkt->payload.mtc.ctc);
		break;
	case ppt_cyc:
		printf("  CYC       0x%lx\n",
		    (unsigned long)pkt->payload.cyc.value);
		break;
	case ppt_ovf:
		printf("  OVF\n");
		break;
	case ppt_ptw:
		printf("  PTW       ip=%d payload=0x%016lx\n",
		    pkt->payload.ptw.ip,
		    (unsigned long)pkt->payload.ptw.payload);
		break;
	case ppt_stop:
		printf("  STOP\n");
		break;
	case ppt_vmcs:
		printf("  VMCS      0x%016lx\n",
		    (unsigned long)pkt->payload.vmcs.base);
		break;
	case ppt_mnt:
		printf("  MNT       0x%016lx\n",
		    (unsigned long)pkt->payload.mnt.payload);
		break;
	case ppt_exstop:
		printf("  EXSTOP    ip=%d\n", pkt->payload.exstop.ip);
		break;
	case ppt_pad:
		break;
	default:
		printf("  ???       type=%d size=%u\n", pkt->type, pkt->size);
		break;
	}
}

/* ------------------------------------------------------------------ */
/* Packet-level JSON output                                            */
/* ------------------------------------------------------------------ */

static void
emit_packet_json(const struct pt_packet *pkt)
{
	char tnt[65];

	switch (pkt->type) {
	case ppt_psb:
		printf("{\"pkt\":\"psb\"}\n");
		break;
	case ppt_psbend:
		printf("{\"pkt\":\"psbend\"}\n");
		break;
	case ppt_tip:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("{\"pkt\":\"tip\",\"ip\":null}\n");
		else
			printf("{\"pkt\":\"tip\",\"ip\":\"0x%lx\"}\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tip_pge:
		printf("{\"pkt\":\"tip_pge\",\"ip\":\"0x%lx\"}\n",
		    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tip_pgd:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("{\"pkt\":\"tip_pgd\",\"ip\":null}\n");
		else
			printf("{\"pkt\":\"tip_pgd\",\"ip\":\"0x%lx\"}\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_fup:
		if (pkt->payload.ip.ipc == pt_ipc_suppressed)
			printf("{\"pkt\":\"fup\",\"ip\":null}\n");
		else
			printf("{\"pkt\":\"fup\",\"ip\":\"0x%lx\"}\n",
			    (unsigned long)pkt->payload.ip.ip);
		break;
	case ppt_tnt_8:
	case ppt_tnt_64:
		tnt_str(tnt, sizeof(tnt), pkt->payload.tnt.payload,
		    pkt->payload.tnt.bit_size);
		printf("{\"pkt\":\"tnt\",\"bits\":\"%s\"}\n", tnt);
		break;
	case ppt_mode:
		if (pkt->payload.mode.leaf == pt_mol_exec)
			printf("{\"pkt\":\"mode_exec\",\"mode\":\"%s\"}\n",
			    exec_mode_str(
			    pt_get_exec_mode(&pkt->payload.mode.bits.exec)));
		else if (pkt->payload.mode.leaf == pt_mol_tsx)
			printf("{\"pkt\":\"mode_tsx\",\"intx\":%d,\"abrt\":%d}\n",
			    pkt->payload.mode.bits.tsx.intx,
			    pkt->payload.mode.bits.tsx.abrt);
		break;
	case ppt_pip:
		printf("{\"pkt\":\"pip\",\"cr3\":\"0x%lx\",\"nr\":%d}\n",
		    (unsigned long)pkt->payload.pip.cr3,
		    pkt->payload.pip.nr);
		break;
	case ppt_tsc:
		printf("{\"pkt\":\"tsc\",\"tsc\":%lu}\n",
		    (unsigned long)pkt->payload.tsc.tsc);
		break;
	case ppt_cbr:
		printf("{\"pkt\":\"cbr\",\"ratio\":%u}\n",
		    pkt->payload.cbr.ratio);
		break;
	case ppt_ovf:
		printf("{\"pkt\":\"ovf\"}\n");
		break;
	case ppt_ptw:
		printf("{\"pkt\":\"ptw\",\"ip\":%d,\"payload\":\"0x%lx\"}\n",
		    pkt->payload.ptw.ip,
		    (unsigned long)pkt->payload.ptw.payload);
		break;
	case ppt_stop:
		printf("{\"pkt\":\"stop\"}\n");
		break;
	case ppt_pad:
		break;
	default:
		break;
	}
}

/* ------------------------------------------------------------------ */
/* Packet-level decoder                                                */
/* ------------------------------------------------------------------ */

int
decode_pt_buffer(const void *buf, size_t len, enum bsdtrace_fmt fmt)
{
	struct pt_config config;
	struct pt_packet_decoder *decoder;
	struct pt_packet pkt;
	int total, errors, syncs;
	int status;

	if (buf == NULL || len == 0) {
		warnx("no PT data to decode");
		return (-1);
	}

	pt_config_init(&config);
	config.begin = __DECONST(uint8_t *, buf);
	config.end = __DECONST(uint8_t *, buf) + len;

	if (pt_cpu_read(&config.cpu) == 0)
		pt_cpu_errata(&config.errata, &config.cpu);

	decoder = pt_pkt_alloc_decoder(&config);
	if (decoder == NULL) {
		warnx("pt_pkt_alloc_decoder failed");
		return (-1);
	}

	if (fmt == FMT_TEXT) {
		fprintf(stderr,
		    "\nPT Packets (%zu bytes)\n"
		    "────────────────────────────────────────\n", len);
	}

	total = 0;
	errors = 0;
	syncs = 0;

	status = pt_pkt_sync_forward(decoder);
	while (status >= 0) {
		syncs++;

		for (;;) {
			status = pt_pkt_next(decoder, &pkt, sizeof(pkt));
			if (status < 0)
				break;

			total++;

			if (fmt == FMT_JSON)
				emit_packet_json(&pkt);
			else
				emit_packet_text(&pkt);
		}

		if (status == -pte_eos)
			break;

		errors++;
		status = pt_pkt_sync_forward(decoder);
	}

	pt_pkt_free_decoder(decoder);

	if (fmt == FMT_TEXT)
		fprintf(stderr,
		    "%d packets decoded, %d sync points, %d errors\n",
		    total, syncs, errors);

	return (total > 0 ? 0 : -1);
}

/* ================================================================== */
/* Instruction-level decoder                                           */
/* ================================================================== */

/* ------------------------------------------------------------------ */
/* Image builder — orchestrates elf.c and symbols.c                    */
/* ------------------------------------------------------------------ */

static struct pt_image *
build_pt_image(const struct pt_image_info *sections, int nsections,
    struct sym_table *st, bool verbose)
{
	struct pt_image *image;
	char interp[MAXPATHLEN];
	uint64_t base_vaddr;
	int64_t slide;
	int total, i;
	Elf *elf;
	int fd;

	if (elf_version(EV_CURRENT) == EV_NONE) {
		warnx("elf_version: %s", elf_errmsg(-1));
		return (NULL);
	}

	image = pt_image_alloc("bsdtrace");
	if (image == NULL)
		return (NULL);

	total = 0;
	for (i = 0; i < nsections; i++) {
		uint64_t load_addr;
		bool have_load_addr;

		if (!section_should_use(sections, nsections, i))
			continue;

		load_addr = sections[i].load_addr;
		have_load_addr = false;
		fd = open(sections[i].path, O_RDONLY);
		if (fd >= 0) {
			elf = elf_begin(fd, ELF_C_READ, NULL);
			if (elf != NULL) {
				if (elf_effective_load_addr(elf,
				    sections[i].type,
				    sections[i].load_addr, &load_addr) == 0)
					have_load_addr = true;
				elf_end(elf);
			}
			close(fd);
		}
		if (!have_load_addr)
			continue;

		{
			int segs = add_elf_to_image(image,
			    sections[i].path, load_addr);
			total += segs;
			if (verbose) {
				fprintf(stderr,
				    "  [%d] %s type=%d rec_addr=0x%lx "
				    "load_addr=0x%lx segs=%d\n",
				    i, sections[i].path, sections[i].type,
				    (unsigned long)sections[i].load_addr,
				    (unsigned long)load_addr, segs);
			}
		}

		/* Load symbols with the same slide. */
		fd = open(sections[i].path, O_RDONLY);
		if (fd >= 0) {
			elf = elf_begin(fd, ELF_C_READ, NULL);
			if (elf != NULL) {
				if (elf_base_vaddr(elf, &base_vaddr) == 0) {
					slide = (int64_t)load_addr -
					    (int64_t)base_vaddr;
					if (verbose) {
						fprintf(stderr,
						    "    base_vaddr=0x%lx "
						    "slide=0x%lx\n",
						    (unsigned long)base_vaddr,
						    (unsigned long)slide);
					}
					sym_table_add_elf(st,
					    sections[i].path, slide);
				}
				elf_end(elf);
			}
			close(fd);
		}

		/*
		 * Handle interpreter for EXEC records.
		 *
		 * Skip if the interpreter already has its own MMAP
		 * section — that section will be processed on its
		 * own iteration and we'd just duplicate the work.
		 */
		if (sections[i].type == HWT_RECORD_EXECUTABLE &&
		    is_user_addr(sections[i].base_addr) &&
		    sections[i].base_addr != load_addr) {
			if (elf_get_interp(sections[i].path,
			    interp, sizeof(interp)) == 0) {
				int k;
				bool have_mmap = false;

				for (k = 0; k < nsections; k++) {
					if (sections[k].type ==
					    HWT_RECORD_MMAP &&
					    strcmp(sections[k].path,
					    interp) == 0) {
						have_mmap = true;
						break;
					}
				}

				if (!have_mmap) {
					total += add_elf_to_image(image,
					    interp,
					    sections[i].base_addr);

					fd = open(interp, O_RDONLY);
					if (fd >= 0) {
						elf = elf_begin(fd,
						    ELF_C_READ, NULL);
						if (elf != NULL) {
							if (elf_base_vaddr(
							    elf,
							    &base_vaddr)
							    == 0) {
								slide =
								    (int64_t)sections[i].base_addr -
								    (int64_t)base_vaddr;
								sym_table_add_elf(
								    st, interp,
								    slide);
							}
							elf_end(elf);
						}
						close(fd);
					}
				}
			}
		}
	}

	sym_table_sort(st);

	if (verbose) {
		fprintf(stderr, "image: %d sections, %d segments, %d symbols\n",
		    nsections, total, st->count);
	}

	if (total == 0) {
		warnx("no executable segments found in %d binaries",
		    nsections);
		pt_image_free(image);
		return (NULL);
	}

	return (image);
}

/* ------------------------------------------------------------------ */
/* Instruction classification                                          */
/* ------------------------------------------------------------------ */

static const char *
insn_class_str(enum pt_insn_class iclass)
{

	switch (iclass) {
	case ptic_call:		return ("CALL");
	case ptic_return:	return ("RETURN");
	case ptic_jump:		return ("JUMP");
	case ptic_cond_jump:	return ("CJMP");
	case ptic_far_call:	return ("SYSCALL");
	case ptic_far_return:	return ("SYSRET");
	case ptic_far_jump:	return ("FARJMP");
	case ptic_ptwrite:	return ("PTWRITE");
	default:		return (NULL);
	}
}

static const char *
path_basename(const char *path)
{
	const char *slash;

	slash = strrchr(path, '/');
	if (slash != NULL && slash[1] != '\0')
		return (slash + 1);
	return (path);
}

static int
collect_exec_binaries(const struct pt_image_info *sections, int nsections,
    char exec_bins[][64], int maxbins)
{
	const char *bn;
	int i, j, nbins;

	nbins = 0;
	for (i = 0; i < nsections && nbins < maxbins; i++) {
		if (sections[i].type != HWT_RECORD_EXECUTABLE)
			continue;
		if (sections[i].path[0] == '\0')
			continue;

		bn = path_basename(sections[i].path);
		for (j = 0; j < nbins; j++) {
			if (strcmp(exec_bins[j], bn) == 0)
				break;
		}
		if (j != nbins)
			continue;

		strlcpy(exec_bins[nbins], bn, sizeof(exec_bins[nbins]));
		nbins++;
	}

	return (nbins);
}

static bool
is_exec_binary(const char *binary, char exec_bins[][64], int nbins)
{
	int i;

	if (binary == NULL || binary[0] == '\0')
		return (false);

	for (i = 0; i < nbins; i++) {
		if (strcmp(exec_bins[i], binary) == 0)
			return (true);
	}

	return (false);
}

int
decode_pt_probe(const void *buf, size_t len,
    const struct pt_image_info *sections, int nsections,
    struct decode_probe_result *result)
{
	struct pt_config config;
	struct pt_insn_decoder *decoder;
	struct pt_image *image;
	struct sym_table st;
	struct bin_range ranges[MAX_BIN_RANGES];
	struct pt_insn insn;
	struct decode_probe_result probe;
	char exec_bins[16][64];
	const struct sym_entry *sym;
	const char *bn;
	uint64_t boff;
	int nbins, nranges, status;

	if (result == NULL)
		return (-1);

	memset(&probe, 0, sizeof(probe));
	*result = probe;

	if (buf == NULL || len == 0 || nsections <= 0)
		return (-1);

	sym_table_init(&st);

	image = build_pt_image(sections, nsections, &st, false);
	if (image == NULL) {
		sym_table_free(&st);
		return (-1);
	}

	nbins = collect_exec_binaries(sections, nsections, exec_bins,
	    nitems(exec_bins));
	nranges = build_bin_ranges(sections, nsections, ranges,
	    MAX_BIN_RANGES);

	pt_config_init(&config);
	config.begin = __DECONST(uint8_t *, buf);
	config.end = __DECONST(uint8_t *, buf) + len;

	if (pt_cpu_read(&config.cpu) == 0)
		pt_cpu_errata(&config.errata, &config.cpu);

	decoder = pt_insn_alloc_decoder(&config);
	if (decoder == NULL) {
		pt_image_free(image);
		sym_table_free(&st);
		return (-1);
	}

	status = pt_insn_set_image(decoder, image);
	if (status < 0) {
		pt_insn_free_decoder(decoder);
		pt_image_free(image);
		sym_table_free(&st);
		return (-1);
	}

	status = pt_insn_sync_forward(decoder);
	while (status >= 0) {
		while (status & pts_event_pending) {
			struct pt_event ev;

			status = pt_insn_event(decoder, &ev, sizeof(ev));
			if (status < 0)
				break;
		}
		if (status < 0)
			break;

		status = pt_insn_next(decoder, &insn, sizeof(insn));
		if (status < 0) {
			if (status == -pte_eos)
				break;
			status = pt_insn_sync_forward(decoder);
			continue;
		}

		probe.total++;
		sym = sym_table_lookup(&st, insn.ip);
		bn = NULL;
		boff = 0;
		if (sym == NULL)
			bn = find_binary_for_ip(ranges, nranges, insn.ip,
			    &boff);

		if ((sym != NULL && is_exec_binary(sym->binary, exec_bins, nbins)) ||
		    (bn != NULL && is_exec_binary(bn, exec_bins, nbins)))
			probe.exec_hits++;
	}

	pt_insn_free_decoder(decoder);
	pt_image_free(image);
	sym_table_free(&st);
	*result = probe;
	return (probe.total > 0 ? 0 : -1);
}

/* ------------------------------------------------------------------ */
/* Profile counters                                                    */
/* ------------------------------------------------------------------ */

struct profile_entry {
	const char	*name;		/* sym name (borrowed from sym_table) */
	const char	*binary;	/* binary name (borrowed) */
	int		calls;
	int		returns;
	int		branches;
	uint64_t	cumulative_tsc;	/* sum of per-call TSC deltas */
	uint64_t	entry_tsc;	/* TSC at most recent entry (transient) */
};

struct profile {
	struct profile_entry	*entries;
	int			count;
	int			capacity;
	enum pt_insn_class	prev_class;
};

static void
profile_init(struct profile *p)
{

	memset(p, 0, sizeof(*p));
}

/*
 * Record a profile event.
 *
 * "calls" counts function entries: an instruction at offset 0 within
 * a symbol is an entry (the first instruction after a CALL lands at
 * the target function's start address).
 *
 * "returns" counts RETURN events within the function.
 * "branches" counts JUMP/CJMP events within the function.
 */
static void
profile_record(struct profile *p, const struct sym_entry *sym,
    uint64_t ip, enum pt_insn_class iclass, uint64_t tsc)
{
	struct profile_entry *e;
	int i;

	if (sym == NULL)
		return;

	/* Find or create entry. */
	e = NULL;
	for (i = 0; i < p->count; i++) {
		if (p->entries[i].name == sym->name &&
		    p->entries[i].binary == sym->binary) {
			e = &p->entries[i];
			break;
		}
	}

	if (e == NULL) {
		if (p->count >= p->capacity) {
			int newcap = p->capacity == 0 ? 128 : p->capacity * 2;
			struct profile_entry *newent;

			newent = realloc(p->entries,
			    newcap * sizeof(*newent));
			if (newent == NULL)
				return;
			p->entries = newent;
			p->capacity = newcap;
		}

		e = &p->entries[p->count];
		memset(e, 0, sizeof(*e));
		e->name = sym->name;
		e->binary = sym->binary;
		p->count++;
	}

	/*
	 * Entry at offset 0 after a CALL = function was called.
	 * Must check prev_class to avoid overcounting on sync-at-entry,
	 * tail jumps, or other non-call control flow to function starts.
	 */
	if (ip == sym->addr &&
	    (p->prev_class == ptic_call || p->prev_class == ptic_far_call)) {
		e->calls++;
		if (tsc > 0)
			e->entry_tsc = tsc;
	}

	p->prev_class = iclass;

	/* Accumulate per-call time on return. */
	switch (iclass) {
	case ptic_return:
	case ptic_far_return:
		e->returns++;
		if (tsc > 0 && e->entry_tsc > 0 && tsc > e->entry_tsc) {
			e->cumulative_tsc += tsc - e->entry_tsc;
			e->entry_tsc = 0;
		}
		break;
	case ptic_jump:
	case ptic_cond_jump:
		e->branches++;
		break;
	default:
		break;
	}
}

static int
profile_cmp_calls(const void *a, const void *b)
{
	const struct profile_entry *ea = a;
	const struct profile_entry *eb = b;

	return (eb->calls - ea->calls);
}

static void
profile_print(struct profile *p)
{
	bool have_tsc;
	int i;

	qsort(p->entries, p->count, sizeof(p->entries[0]), profile_cmp_calls);

	/* Check if any entry has TSC data. */
	have_tsc = false;
	for (i = 0; i < p->count; i++) {
		if (p->entries[i].cumulative_tsc > 0) {
			have_tsc = true;
			break;
		}
	}

	if (have_tsc) {
		printf("%-8s %-8s %-8s  %-14s  %-20s  %s\n",
		    "CALLS", "RETURNS", "BRANCHES", "TIME(tsc)",
		    "BINARY", "FUNCTION");
		printf("%-8s %-8s %-8s  %-14s  %-20s  %s\n",
		    "--------", "--------", "--------",
		    "--------------",
		    "--------------------", "--------------------");
	} else {
		printf("%-8s %-8s %-8s  %-20s  %s\n",
		    "CALLS", "RETURNS", "BRANCHES", "BINARY", "FUNCTION");
		printf("%-8s %-8s %-8s  %-20s  %s\n",
		    "--------", "--------", "--------",
		    "--------------------", "--------------------");
	}

	for (i = 0; i < p->count; i++) {
		struct profile_entry *e = &p->entries[i];
		if (e->calls == 0 && e->returns == 0 && e->branches == 0)
			continue;
		if (have_tsc) {
			uint64_t dt = e->cumulative_tsc;
			printf("%-8d %-8d %-8d  %-14lu  %-20s  %s\n",
			    e->calls, e->returns, e->branches,
			    (unsigned long)dt, e->binary, e->name);
		} else {
			printf("%-8d %-8d %-8d  %-20s  %s\n",
			    e->calls, e->returns, e->branches,
			    e->binary, e->name);
		}
	}
}

static void
profile_free(struct profile *p)
{

	free(p->entries);
	p->entries = NULL;
	p->count = 0;
	p->capacity = 0;
}

/* ------------------------------------------------------------------ */
/* Call tree                                                            */
/* ------------------------------------------------------------------ */

struct ct_node {
	const char		*name;		/* borrowed from sym_table */
	const char		*binary;	/* borrowed from sym_table */
	int			count;		/* times called at this position */
	uint64_t		total_tsc;	/* accumulated TSC ticks */
	uint64_t		entry_tsc;	/* TSC at push (transient) */
	struct ct_node		*children;
	int			nchildren;
	int			children_cap;
};

struct calltree {
	struct ct_node		root;		/* virtual root */
	struct ct_node		**stack;	/* shadow call stack */
	int			depth;
	int			stack_cap;
	const struct sym_entry	*prev_sym;
	enum pt_insn_class	prev_class;
};

static void
ct_node_init(struct ct_node *n, const char *name, const char *binary)
{

	memset(n, 0, sizeof(*n));
	n->name = name;
	n->binary = binary;
}

static struct ct_node *
ct_find_or_add_child(struct ct_node *parent, const char *name,
    const char *binary)
{
	int i;

	for (i = 0; i < parent->nchildren; i++) {
		if (parent->children[i].name == name &&
		    parent->children[i].binary == binary)
			return (&parent->children[i]);
	}

	if (parent->nchildren >= parent->children_cap) {
		int newcap = parent->children_cap == 0 ?
		    8 : parent->children_cap * 2;
		struct ct_node *newc;

		newc = realloc(parent->children,
		    newcap * sizeof(*newc));
		if (newc == NULL)
			return (NULL);
		parent->children = newc;
		parent->children_cap = newcap;
	}

	ct_node_init(&parent->children[parent->nchildren], name, binary);
	return (&parent->children[parent->nchildren++]);
}

static void
calltree_init(struct calltree *ct)
{

	memset(ct, 0, sizeof(*ct));
	ct_node_init(&ct->root, "<root>", "");
	ct->stack_cap = 256;
	ct->stack = calloc(ct->stack_cap, sizeof(*ct->stack));
	ct->stack[0] = &ct->root;
	ct->depth = 0;
}

static void
calltree_push(struct calltree *ct, const struct sym_entry *sym,
    uint64_t tsc)
{
	struct ct_node *parent, *child;

	if (sym == NULL)
		return;

	parent = ct->stack[ct->depth];
	child = ct_find_or_add_child(parent, sym->name, sym->binary);
	if (child == NULL)
		return;
	child->count++;
	child->entry_tsc = tsc;

	ct->depth++;
	if (ct->depth >= ct->stack_cap) {
		int newcap = ct->stack_cap * 2;
		struct ct_node **news;

		news = realloc(ct->stack, newcap * sizeof(*news));
		if (news == NULL) {
			ct->depth--;
			return;
		}
		ct->stack = news;
		ct->stack_cap = newcap;
	}
	ct->stack[ct->depth] = child;
}

static void
calltree_pop(struct calltree *ct, uint64_t tsc)
{

	if (ct->depth > 0) {
		struct ct_node *node = ct->stack[ct->depth];
		if (tsc > 0 && node->entry_tsc > 0 &&
		    tsc > node->entry_tsc)
			node->total_tsc += tsc - node->entry_tsc;
		node->entry_tsc = 0;
		ct->depth--;
	}
}

/*
 * Feed each decoded instruction to the call tree.
 * Push on CALL (using the callee's symbol), pop on RETURN.
 */
static void
calltree_record(struct calltree *ct, const struct sym_entry *sym,
    uint64_t ip, enum pt_insn_class iclass, uint64_t tsc)
{

	/*
	 * Detect function entry: the previous instruction was a CALL
	 * and we're now at offset 0 of a new symbol.
	 */
	if (sym != NULL && ip == sym->addr &&
	    (ct->prev_class == ptic_call ||
	     ct->prev_class == ptic_far_call)) {
		calltree_push(ct, sym, tsc);
	}

	if (iclass == ptic_return || iclass == ptic_far_return)
		calltree_pop(ct, tsc);

	ct->prev_sym = sym;
	ct->prev_class = iclass;
}

static int
ct_cmp_count(const void *a, const void *b)
{
	const struct ct_node *na = a;
	const struct ct_node *nb = b;

	return (nb->count - na->count);
}

static void
ct_print_node(struct ct_node *n, int indent)
{
	int i;

	/* Sort children by call count descending. */
	if (n->nchildren > 1)
		qsort(n->children, n->nchildren, sizeof(n->children[0]),
		    ct_cmp_count);

	for (i = 0; i < n->nchildren; i++) {
		struct ct_node *c = &n->children[i];
		if (c->total_tsc > 0)
			printf("%*s%s:%s  (%d) [%lu tsc]\n",
			    indent * 2, "", c->binary, c->name,
			    c->count, (unsigned long)c->total_tsc);
		else
			printf("%*s%s:%s  (%d)\n",
			    indent * 2, "", c->binary, c->name, c->count);
		ct_print_node(c, indent + 1);
	}
}

static void
calltree_print(struct calltree *ct)
{

	ct_print_node(&ct->root, 0);
}

static int
ct_node_count(struct ct_node *n)
{
	int total, i;

	total = n->nchildren;
	for (i = 0; i < n->nchildren; i++)
		total += ct_node_count(&n->children[i]);
	return (total);
}

static void
ct_node_free(struct ct_node *n)
{
	int i;

	for (i = 0; i < n->nchildren; i++)
		ct_node_free(&n->children[i]);
	free(n->children);
	n->children = NULL;
	n->nchildren = 0;
}

static void
calltree_free(struct calltree *ct)
{

	ct_node_free(&ct->root);
	free(ct->stack);
	ct->stack = NULL;
}

/* ------------------------------------------------------------------ */
/* Collapsed (folded) stacks for flamegraph.pl / Speedscope            */
/* ------------------------------------------------------------------ */

#define	MAX_COLLAPSED_STACKS	4096
#define	MAX_STACK_DEPTH		256

struct collapsed_entry {
	char	*stack;		/* "func1;func2;func3" (strdup'd) */
	int	count;
};

struct collapsed {
	struct collapsed_entry	*entries;
	int			count;
	int			capacity;
	/* Current shadow call stack. */
	const char		*names[MAX_STACK_DEPTH];
	int			depth;
	const struct sym_entry	*prev_sym;
	enum pt_insn_class	prev_class;
};

static void
collapsed_init(struct collapsed *col)
{

	memset(col, 0, sizeof(*col));
}

/*
 * Build the stack string by joining names[0..depth-1] with ";".
 * Returns a malloc'd string, or NULL on failure.
 */
static char *
collapsed_build_stack(struct collapsed *col)
{
	char buf[8192];
	int i, off;

	if (col->depth <= 0)
		return (NULL);

	off = 0;
	for (i = 0; i < col->depth; i++) {
		if (i > 0 && off < (int)sizeof(buf) - 1)
			buf[off++] = ';';
		off += snprintf(buf + off, sizeof(buf) - off, "%s",
		    col->names[i]);
		if (off >= (int)sizeof(buf) - 1)
			break;
	}
	buf[off] = '\0';
	return (strdup(buf));
}

/*
 * Find or create the entry for the current stack and increment it.
 */
static void
collapsed_count_stack(struct collapsed *col)
{
	char *stack;
	int i;

	stack = collapsed_build_stack(col);
	if (stack == NULL)
		return;

	/* Look for existing entry. */
	for (i = 0; i < col->count; i++) {
		if (strcmp(col->entries[i].stack, stack) == 0) {
			col->entries[i].count++;
			free(stack);
			return;
		}
	}

	/* Add new entry. */
	if (col->count >= col->capacity) {
		int newcap = col->capacity == 0 ?
		    256 : col->capacity * 2;
		struct collapsed_entry *newent;

		if (newcap > MAX_COLLAPSED_STACKS)
			newcap = MAX_COLLAPSED_STACKS;
		if (col->count >= newcap) {
			static bool warned;
			if (!warned) {
				warnx("collapsed stacks: hit %d unique "
				    "stack limit, dropping new stacks",
				    MAX_COLLAPSED_STACKS);
				warned = true;
			}
			free(stack);
			return;
		}
		newent = realloc(col->entries,
		    newcap * sizeof(*newent));
		if (newent == NULL) {
			free(stack);
			return;
		}
		col->entries = newent;
		col->capacity = newcap;
	}

	col->entries[col->count].stack = stack;
	col->entries[col->count].count = 1;
	col->count++;
}

/*
 * Feed each decoded instruction to the collapsed stack tracker.
 * Push on CALL (function entry at offset 0), count+pop on RETURN.
 *
 * Counting on RETURN (not PUSH) gives correct flamegraph semantics:
 * a call chain main→foo→bar produces one sample at "main;foo;bar"
 * instead of three separate prefix samples.
 */
static void
collapsed_record(struct collapsed *col, const struct sym_entry *sym,
    uint64_t ip, enum pt_insn_class iclass)
{

	/* Detect function entry. */
	if (sym != NULL && ip == sym->addr &&
	    (col->prev_class == ptic_call ||
	     col->prev_class == ptic_far_call)) {
		if (col->depth < MAX_STACK_DEPTH) {
			col->names[col->depth] = sym->name;
			col->depth++;
		}
	}

	if (iclass == ptic_return || iclass == ptic_far_return) {
		collapsed_count_stack(col);
		if (col->depth > 0)
			col->depth--;
	}

	col->prev_sym = sym;
	col->prev_class = iclass;
}

static int
collapsed_cmp_count(const void *a, const void *b)
{
	const struct collapsed_entry *ea = a;
	const struct collapsed_entry *eb = b;

	return (eb->count - ea->count);
}

static void
collapsed_print(struct collapsed *col)
{

	qsort(col->entries, col->count, sizeof(col->entries[0]),
	    collapsed_cmp_count);

	for (int i = 0; i < col->count; i++)
		printf("%s %d\n", col->entries[i].stack,
		    col->entries[i].count);
}

static void
collapsed_free(struct collapsed *col)
{
	int i;

	for (i = 0; i < col->count; i++)
		free(col->entries[i].stack);
	free(col->entries);
	col->entries = NULL;
	col->count = 0;
	col->capacity = 0;
}

/* ------------------------------------------------------------------ */
/* Instruction decoder                                                 */
/* ------------------------------------------------------------------ */

int
decode_pt_insn(const void *buf, size_t len,
    const struct pt_image_info *sections, int nsections,
    enum bsdtrace_fmt fmt, const struct pt_decode_opts *opts)
{
	struct pt_config config;
	struct pt_insn_decoder *decoder;
	struct pt_image *image;
	struct sym_table st;
	struct bin_range ranges[MAX_BIN_RANGES];
	int nranges;
	struct profile prof;
	struct calltree ct;
	struct collapsed col;
	struct pt_insn insn;
	const struct sym_entry *sym;
	const char *bn;
	const char *label;
	const char *syscall_name;
	uint64_t boff;
	uint64_t tsc;
	uint32_t lost_mtc, lost_cyc;
	int tid;
	int status;
	int total, calls, branches, returns, syscalls, nomaps, errors;
	int ovf_count;
	uint32_t total_lost_mtc, total_lost_cyc;

	if (buf == NULL || len == 0) {
		warnx("no PT data to decode");
		return (-1);
	}

	if (nsections <= 0) {
		warnx("no image sections — falling back to packet decode");
		return (decode_pt_buffer(buf, len, fmt));
	}

	sym_table_init(&st);
	profile_init(&prof);
	calltree_init(&ct);
	collapsed_init(&col);

	image = build_pt_image(sections, nsections, &st, true);
	if (image == NULL) {
		sym_table_free(&st);
		warnx("image build failed — falling back to packet decode");
		return (decode_pt_buffer(buf, len, fmt));
	}

	nranges = build_bin_ranges(sections, nsections, ranges,
	    MAX_BIN_RANGES);

	pt_config_init(&config);
	config.begin = __DECONST(uint8_t *, buf);
	config.end = __DECONST(uint8_t *, buf) + len;
	tid = opts != NULL ? opts->tid : -1;

	if (pt_cpu_read(&config.cpu) == 0)
		pt_cpu_errata(&config.errata, &config.cpu);
	if (opts != NULL && opts->mtc_freq > 0) {
		config.mtc_freq = opts->mtc_freq;
		config.flags.variant.insn.enable_tick_events = 1;
	}

	decoder = pt_insn_alloc_decoder(&config);
	if (decoder == NULL) {
		warnx("pt_insn_alloc_decoder failed");
		pt_image_free(image);
		sym_table_free(&st);
		return (-1);
	}

	status = pt_insn_set_image(decoder, image);
	if (status < 0) {
		warnx("pt_insn_set_image failed: %s",
		    pt_errstr(pt_errcode(status)));
		pt_insn_free_decoder(decoder);
		pt_image_free(image);
		sym_table_free(&st);
		return (-1);
	}

	if (fmt == FMT_TEXT) {
		if (tid >= 0)
			fprintf(stderr,
			    "\nPT Instructions (%zu bytes, tid=%d)\n"
			    "────────────────────────────────────────\n",
			    len, tid);
		else
			fprintf(stderr,
			    "\nPT Instructions (%zu bytes)\n"
			    "────────────────────────────────────────\n",
			    len);
	}

	total = 0;
	calls = 0;
	branches = 0;
	returns = 0;
	syscalls = 0;
	nomaps = 0;
	errors = 0;
	ovf_count = 0;
	total_lost_mtc = 0;
	total_lost_cyc = 0;

	status = pt_insn_sync_forward(decoder);
	while (status >= 0) {
		while (status & pts_event_pending) {
			struct pt_event ev;
			status = pt_insn_event(decoder, &ev, sizeof(ev));
			if (status < 0)
				break;
			if (ev.type == ptev_overflow)
				ovf_count++;
			if (ev.type == ptev_ptwrite) {
				if (fmt == FMT_JSON)
					printf("{\"ptwrite\":\"0x%lx\","
					    "\"ip\":\"0x%lx\"}\n",
					    (unsigned long)ev.variant.ptwrite.payload,
					    (unsigned long)ev.variant.ptwrite.ip);
				else if (fmt == FMT_TEXT)
					printf("  PTWRITE   0x%016lx  ip=0x%lx\n",
					    (unsigned long)ev.variant.ptwrite.payload,
					    (unsigned long)ev.variant.ptwrite.ip);
			}
		}
		if (status < 0)
			break;

		status = pt_insn_next(decoder, &insn, sizeof(insn));
		if (status < 0) {
			if (status == -pte_eos)
				break;

			if (status == -pte_nomap)
				nomaps++;
			else
				errors++;

			status = pt_insn_sync_forward(decoder);
			continue;
		}

		/* Extract timing — tsc stays 0 if unavailable. */
		tsc = 0;
		lost_mtc = 0;
		lost_cyc = 0;
		pt_insn_time(decoder, &tsc, &lost_mtc, &lost_cyc);
		total_lost_mtc += lost_mtc;
		total_lost_cyc += lost_cyc;

		total++;
		label = insn_class_str(insn.iclass);

		switch (insn.iclass) {
		case ptic_call:
			calls++;
			break;
		case ptic_jump:
		case ptic_cond_jump:
			branches++;
			break;
		case ptic_return:
			returns++;
			break;
		case ptic_far_call:
			syscalls++;
			break;
		case ptic_far_return:
		case ptic_far_jump:
			break;
		default:
			break;
		}

		/*
		 * Profile/tree/collapsed modes need every instruction
		 * (including ptic_other) to detect function entries
		 * at offset 0.
		 */
		if (fmt == FMT_PROFILE || fmt == FMT_TREE ||
		    fmt == FMT_COLLAPSED) {
			sym = sym_table_lookup(&st, insn.ip);
			if (fmt == FMT_PROFILE)
				profile_record(&prof, sym, insn.ip,
				    insn.iclass, tsc);
			else if (fmt == FMT_TREE)
				calltree_record(&ct, sym, insn.ip,
				    insn.iclass, tsc);
			else
				collapsed_record(&col, sym, insn.ip,
				    insn.iclass);
			continue;
		}

		if (label == NULL)
			continue;

		sym = sym_table_lookup(&st, insn.ip);
		bn = NULL;
		boff = 0;
		if (sym == NULL)
			bn = find_binary_for_ip(ranges, nranges, insn.ip,
			    &boff);

		/*
		 * Syscall name resolution: libsys wrappers are named
		 * __sys_write, __sys_read, etc.  Extract the syscall
		 * name for display alongside the full symbol.
		 */
#define	SYSCALL_PREFIX	"__sys_"
		syscall_name = NULL;
		if (insn.iclass == ptic_far_call && sym != NULL &&
		    strncmp(sym->name, SYSCALL_PREFIX,
		    sizeof(SYSCALL_PREFIX) - 1) == 0)
			syscall_name = sym->name +
			    sizeof(SYSCALL_PREFIX) - 1;

		if (fmt == FMT_JSON) {
			if (sym != NULL) {
				char esym[256], ebin[256];
				json_escape(esym, sizeof(esym), sym->name);
				json_escape(ebin, sizeof(ebin), sym->binary);
				printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\","
				    "\"sym\":\"%s\",\"off\":%lu,"
				    "\"bin\":\"%s\"",
				    label,
				    (unsigned long)insn.ip,
				    esym,
				    (unsigned long)(insn.ip - sym->addr),
				    ebin);
				if (syscall_name != NULL) {
					char esc[256];
					json_escape(esc, sizeof(esc),
					    syscall_name);
					printf(",\"syscall\":\"%s\"", esc);
				}
			} else if (bn != NULL) {
				char ebin[256];
				json_escape(ebin, sizeof(ebin), bn);
				printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\","
				    "\"off\":%lu,\"bin\":\"%s\"",
				    label,
				    (unsigned long)insn.ip,
				    (unsigned long)boff,
				    ebin);
			} else {
				printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\"",
				    label,
				    (unsigned long)insn.ip);
			}
			if (tsc > 0)
				printf(",\"tsc\":%lu",
				    (unsigned long)tsc);
			if (tid >= 0)
				printf(",\"tid\":%d", tid);
			printf("}\n");
		} else {
			if (sym != NULL) {
				uint64_t off = insn.ip - sym->addr;
				if (syscall_name != NULL) {
					if (off == 0)
						printf("  %-9s %s (%s:%s)\n",
						    label, syscall_name,
						    sym->binary, sym->name);
					else
						printf("  %-9s %s (%s:%s+0x%lx)\n",
						    label, syscall_name,
						    sym->binary, sym->name,
						    (unsigned long)off);
				} else if (off == 0) {
					printf("  %-9s %s:%s\n",
					    label, sym->binary,
					    sym->name);
				} else {
					printf("  %-9s %s:%s+0x%lx\n",
					    label, sym->binary,
					    sym->name,
					    (unsigned long)off);
				}
			} else {
				if (bn != NULL)
					printf("  %-9s %s+0x%lx\n",
					    label, bn,
					    (unsigned long)boff);
				else
					printf("  %-9s 0x%016lx\n",
					    label,
					    (unsigned long)insn.ip);
			}
		}
	}

	pt_insn_free_decoder(decoder);
	pt_image_free(image);

	if (fmt == FMT_PROFILE) {
		if (tid >= 0)
			printf("Thread %d:\n", tid);
		profile_print(&prof);
		fprintf(stderr,
		    "%d instructions, %d functions profiled\n",
		    total, prof.count);
	} else if (fmt == FMT_TREE) {
		if (tid >= 0)
			printf("Thread %d:\n", tid);
		calltree_print(&ct);
		fprintf(stderr,
		    "%d instructions, %d call tree nodes\n",
		    total, ct_node_count(&ct.root));
	} else if (fmt == FMT_COLLAPSED) {
		if (tid >= 0)
			fprintf(stderr, "Thread %d:\n", tid);
		collapsed_print(&col);
		fprintf(stderr,
		    "%d instructions, %d unique stacks\n",
		    total, col.count);
	} else if (fmt == FMT_TEXT) {
		fflush(stdout);
		fprintf(stderr,
		    "%d instructions, %d calls, %d returns, "
		    "%d branches, %d syscalls, %d nomap, %d errors\n",
		    total, calls, returns, branches, syscalls,
		    nomaps, errors);
	}

	if (ovf_count > 0)
		fprintf(stderr,
		    "warning: %d overflow event(s) — trace data was lost\n",
		    ovf_count);
	if (total_lost_mtc > 0 || total_lost_cyc > 0)
		fprintf(stderr,
		    "warning: lost timing packets — mtc=%u cyc=%u\n",
		    total_lost_mtc, total_lost_cyc);

	collapsed_free(&col);
	calltree_free(&ct);
	profile_free(&prof);
	sym_table_free(&st);
	return (total > 0 ? 0 : -1);
}
