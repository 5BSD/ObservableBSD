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
 * events (calls, returns, branches, syscalls).  ELF program headers
 * are parsed directly to find executable PT_LOAD segments.
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

#include "bptrace.h"

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

/*
 * Render a TNT bit vector as a string of '!' (taken) and '.' (not-taken).
 * buf must be at least 65 bytes (64 bits + NUL).
 */
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
/* Text output                                                         */
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
		/* Skip padding packets — too noisy. */
		break;
	default:
		printf("  ???       type=%d size=%u\n", pkt->type, pkt->size);
		break;
	}
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
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
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
decode_pt_buffer(const void *buf, size_t len, enum bptrace_fmt fmt)
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

	/*
	 * pt_config wants non-const pointers (the encoder API writes
	 * through them).  The packet decoder only reads, so this cast
	 * is safe.
	 */
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

	/* Find first PSB and start decoding. */
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

		/* Try to resync on the next PSB. */
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
/* ELF parsing via libelf/gelf                                         */
/* ------------------------------------------------------------------ */

/*
 * Add executable code segments from an ELF binary to a pt_image.
 *
 * Uses libelf/gelf (portable across 32/64-bit ELF classes) to read
 * program headers, find PT_LOAD segments with PF_X, and add each
 * one to the image at its runtime virtual address.
 *
 * The runtime address is computed as:
 *   slide = load_addr - first_PT_LOAD.p_vaddr
 *   runtime_vaddr = phdr.p_vaddr + slide
 *
 * For PIE executables and shared libraries, the ELF p_vaddr values
 * are relative offsets (first PT_LOAD usually at 0x0).  load_addr
 * is the runtime mapping address from the HWT EXEC/MMAP record.
 */
static int
add_elf_to_image(struct pt_image *image, const char *path,
    uint64_t load_addr)
{
	Elf *elf;
	GElf_Ehdr ehdr;
	GElf_Phdr phdr;
	size_t phdrnum;
	uint64_t base_vaddr, runtime_vaddr;
	int64_t slide;
	int fd, added, err;
	size_t i;
	bool found_base;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return (0);

	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		close(fd);
		return (0);
	}

	if (gelf_getehdr(elf, &ehdr) == NULL)
		goto done;

	if (elf_getphdrnum(elf, &phdrnum) != 0)
		goto done;

	/* Find the base vaddr (first PT_LOAD segment). */
	found_base = false;
	base_vaddr = 0;
	for (i = 0; i < phdrnum; i++) {
		if (gelf_getphdr(elf, (int)i, &phdr) == NULL)
			continue;
		if (phdr.p_type == PT_LOAD) {
			base_vaddr = phdr.p_vaddr;
			found_base = true;
			break;
		}
	}
	if (!found_base)
		goto done;

	slide = (int64_t)load_addr - (int64_t)base_vaddr;

	/* Add each executable PT_LOAD segment. */
	added = 0;
	for (i = 0; i < phdrnum; i++) {
		if (gelf_getphdr(elf, (int)i, &phdr) == NULL)
			continue;
		if (phdr.p_type != PT_LOAD)
			continue;
		if (!(phdr.p_flags & PF_X))
			continue;
		if (phdr.p_filesz == 0)
			continue;

		runtime_vaddr = phdr.p_vaddr + slide;

		err = pt_image_add_file(image, path,
		    phdr.p_offset, phdr.p_filesz,
		    NULL, runtime_vaddr);
		if (err >= 0)
			added++;
	}

	elf_end(elf);
	close(fd);
	return (added);

done:
	elf_end(elf);
	close(fd);
	return (0);
}

/* ------------------------------------------------------------------ */
/* ELF interpreter (PT_INTERP) lookup                                  */
/* ------------------------------------------------------------------ */

/*
 * Read the PT_INTERP segment from an ELF binary to find the dynamic
 * linker path (e.g. /libexec/ld-elf.so.1).
 * Returns 0 on success, -1 if not found or not a dynamic binary.
 */
static int
elf_get_interp(const char *path, char *interp, size_t interpsz)
{
	Elf *elf;
	GElf_Phdr phdr;
	Elf_Data *data;
	Elf_Scn *scn;
	size_t phdrnum;
	int fd;
	size_t i;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return (-1);

	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		close(fd);
		return (-1);
	}

	if (elf_getphdrnum(elf, &phdrnum) != 0)
		goto fail;

	for (i = 0; i < phdrnum; i++) {
		if (gelf_getphdr(elf, (int)i, &phdr) == NULL)
			continue;
		if (phdr.p_type != PT_INTERP)
			continue;

		/*
		 * PT_INTERP points to a NUL-terminated path string
		 * in the file at p_offset with length p_filesz.
		 * Read it directly via lseek+read on the fd.
		 */
		if (phdr.p_filesz == 0 || phdr.p_filesz >= interpsz)
			goto fail;

		if (lseek(fd, phdr.p_offset, SEEK_SET) == -1)
			goto fail;

		memset(interp, 0, interpsz);
		if (read(fd, interp, phdr.p_filesz) !=
		    (ssize_t)phdr.p_filesz)
			goto fail;

		elf_end(elf);
		close(fd);
		return (0);
	}

fail:
	elf_end(elf);
	close(fd);
	return (-1);
}

/* ------------------------------------------------------------------ */
/* Image builder                                                       */
/* ------------------------------------------------------------------ */

/*
 * Is base_addr a plausible userspace address?
 * Reject zero and kernel-range addresses (0xfffffe... on amd64).
 */
static bool
is_user_addr(uint64_t addr)
{

	if (addr == 0)
		return (false);
	if (addr >= 0x0000800000000000ULL)
		return (false);
	return (true);
}

static struct pt_image *
build_pt_image(const struct pt_image_info *sections, int nsections)
{
	struct pt_image *image;
	char interp[MAXPATHLEN];
	int total, i;

	if (elf_version(EV_CURRENT) == EV_NONE) {
		warnx("elf_version: %s", elf_errmsg(-1));
		return (NULL);
	}

	image = pt_image_alloc("bptrace");
	if (image == NULL)
		return (NULL);

	total = 0;
	for (i = 0; i < nsections; i++) {
		total += add_elf_to_image(image, sections[i].path,
		    sections[i].load_addr);

		/*
		 * For EXEC records, base_addr is where the kernel
		 * mapped the ELF interpreter (dynamic linker).
		 * Read PT_INTERP from the executable and add the
		 * interpreter to the image at base_addr.
		 */
		if (sections[i].type == HWT_RECORD_EXECUTABLE &&
		    is_user_addr(sections[i].base_addr) &&
		    sections[i].base_addr != sections[i].load_addr) {
			if (elf_get_interp(sections[i].path,
			    interp, sizeof(interp)) == 0) {
				total += add_elf_to_image(image,
				    interp, sections[i].base_addr);
			}
		}
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
/* Instruction classification helpers                                  */
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
    enum bptrace_fmt fmt)
{
	struct pt_config config;
	struct pt_insn_decoder *decoder;
	struct pt_image *image;
	struct pt_insn insn;
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

	image = build_pt_image(sections, nsections);
	if (image == NULL) {
		warnx("image build failed — falling back to packet decode");
		return (decode_pt_buffer(buf, len, fmt));
	}

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
		/*
		 * Drain pending events before decoding instructions.
		 *
		 * Both pt_insn_sync_forward() and pt_insn_next() can
		 * return pts_event_pending.  Events MUST be consumed
		 * via pt_insn_event() before the next pt_insn_next()
		 * call — failure to do so causes decode errors.
		 */
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

			if (status == -pte_nomap) {
				nomaps++;
			} else {
				errors++;
			}

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

		/* Only print branch instructions to avoid flood. */
		if (label == NULL)
			continue;

		if (fmt == FMT_JSON)
			printf("{\"insn\":\"%s\",\"ip\":\"0x%lx\"}\n",
			    label,
			    (unsigned long)insn.ip);
		else
			printf("  %-9s 0x%016lx\n",
			    label,
			    (unsigned long)insn.ip);
	}

	pt_insn_free_decoder(decoder);
	pt_image_free(image);

	if (fmt == FMT_TEXT)
		fprintf(stderr,
		    "%d instructions, %d calls, %d returns, "
		    "%d syscalls, %d nomap, %d errors\n",
		    total, calls, returns, syscalls, nomaps, errors);

	return (total > 0 ? 0 : -1);
}
