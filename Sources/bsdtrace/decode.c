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
    struct sym_table *st)
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
		total += add_elf_to_image(image, sections[i].path,
		    sections[i].load_addr);

		/* Load symbols with the same slide. */
		fd = open(sections[i].path, O_RDONLY);
		if (fd >= 0) {
			elf = elf_begin(fd, ELF_C_READ, NULL);
			if (elf != NULL) {
				if (elf_base_vaddr(elf, &base_vaddr) == 0) {
					slide = (int64_t)
					    sections[i].load_addr -
					    (int64_t)base_vaddr;
					sym_table_add_elf(st,
					    sections[i].path, slide);
				}
				elf_end(elf);
			}
			close(fd);
		}

		/* Handle interpreter for EXEC records. */
		if (sections[i].type == HWT_RECORD_EXECUTABLE &&
		    is_user_addr(sections[i].base_addr) &&
		    sections[i].base_addr != sections[i].load_addr) {
			if (elf_get_interp(sections[i].path,
			    interp, sizeof(interp)) == 0) {
				total += add_elf_to_image(image,
				    interp, sections[i].base_addr);

				fd = open(interp, O_RDONLY);
				if (fd >= 0) {
					elf = elf_begin(fd, ELF_C_READ,
					    NULL);
					if (elf != NULL) {
						if (elf_base_vaddr(elf,
						    &base_vaddr) == 0) {
							slide = (int64_t)
							    sections[i].base_addr -
							    (int64_t)base_vaddr;
							sym_table_add_elf(st,
							    interp, slide);
						}
						elf_end(elf);
					}
					close(fd);
				}
			}
		}
	}

	sym_table_sort(st);

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

/* ------------------------------------------------------------------ */
/* Instruction decoder                                                 */
/* ------------------------------------------------------------------ */

int
decode_pt_insn(const void *buf, size_t len,
    const struct pt_image_info *sections, int nsections,
    enum bsdtrace_fmt fmt)
{
	struct pt_config config;
	struct pt_insn_decoder *decoder;
	struct pt_image *image;
	struct sym_table st;
	struct bin_range ranges[MAX_BIN_RANGES];
	int nranges;
	struct pt_insn insn;
	const struct sym_entry *sym;
	const char *label;
	int status;
	int total, calls, returns, syscalls, nomaps, errors;

	if (buf == NULL || len == 0) {
		warnx("no PT data to decode");
		return (-1);
	}

	if (nsections <= 0) {
		warnx("no image sections — falling back to packet decode");
		return (decode_pt_buffer(buf, len, fmt));
	}

	sym_table_init(&st);

	image = build_pt_image(sections, nsections, &st);
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

	if (pt_cpu_read(&config.cpu) == 0)
		pt_cpu_errata(&config.errata, &config.cpu);

	decoder = pt_insn_alloc_decoder(&config);
	if (decoder == NULL) {
		warnx("pt_insn_alloc_decoder failed");
		pt_image_free(image);
		return (-1);
	}

	pt_insn_set_image(decoder, image);

	if (fmt == FMT_TEXT) {
		fprintf(stderr,
		    "\nPT Instructions (%zu bytes)\n"
		    "────────────────────────────────────────\n", len);
	}

	total = 0;
	calls = 0;
	returns = 0;
	syscalls = 0;
	nomaps = 0;
	errors = 0;

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

			if (status == -pte_nomap)
				nomaps++;
			else
				errors++;

			status = pt_insn_sync_forward(decoder);
			continue;
		}

		total++;
		label = insn_class_str(insn.iclass);

		switch (insn.iclass) {
		case ptic_call:
		case ptic_jump:
			calls++;
			break;
		case ptic_return:
			returns++;
			break;
		case ptic_far_call:
		case ptic_far_return:
		case ptic_far_jump:
			syscalls++;
			break;
		default:
			break;
		}

		if (label == NULL)
			continue;

		sym = sym_table_lookup(&st, insn.ip);

		if (fmt == FMT_JSON) {
			if (sym != NULL)
				printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\","
				    "\"sym\":\"%s\",\"off\":%lu,"
				    "\"bin\":\"%s\"}\n",
				    label,
				    (unsigned long)insn.ip,
				    sym->name,
				    (unsigned long)(insn.ip - sym->addr),
				    sym->binary);
			else
				printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\"}\n",
				    label,
				    (unsigned long)insn.ip);
		} else {
			if (sym != NULL) {
				uint64_t off = insn.ip - sym->addr;
				if (off == 0)
					printf("  %-9s %s:%s\n",
					    label, sym->binary,
					    sym->name);
				else
					printf("  %-9s %s:%s+0x%lx\n",
					    label, sym->binary,
					    sym->name,
					    (unsigned long)off);
			} else {
				const char *bn;
				uint64_t boff;

				bn = find_binary_for_ip(ranges,
				    nranges, insn.ip, &boff);
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

	if (fmt == FMT_TEXT) {
		fflush(stdout);
		fprintf(stderr,
		    "%d instructions, %d calls, %d returns, "
		    "%d syscalls, %d nomap, %d errors, %d symbols\n",
		    total, calls, returns, syscalls, nomaps, errors,
		    st.count);
	}

	sym_table_free(&st);
	return (total > 0 ? 0 : -1);
}
