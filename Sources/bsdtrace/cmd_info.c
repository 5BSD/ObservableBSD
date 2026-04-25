/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace info — show binary layout for trace planning.
 *
 * Static mode: display text segments and exported functions with
 * ELF offsets for a given binary file.
 *
 * PID mode (--pid): read /proc/<pid>/map to find loaded binaries,
 * then show runtime addresses with ASLR slide applied.
 */

#include <sys/types.h>
#include <sys/param.h>

#include <err.h>
#include <fcntl.h>
#include <gelf.h>
#include <libelf.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* ELF info dump                                                       */
/* ------------------------------------------------------------------ */

static void
info_elf(const char *path, uint64_t record_addr, bool has_load_addr,
    int load_type)
{
	Elf *elf;
	Elf_Scn *scn;
	GElf_Ehdr ehdr;
	GElf_Phdr phdr;
	GElf_Shdr shdr;
	Elf_Data *data;
	GElf_Sym sym;
	GElf_Word symtab_type;
	uint64_t load_addr;
	size_t phdrnum, nsyms;
	uint64_t base_vaddr;
	int64_t slide;
	const char *name;
	int fd;
	size_t i;
	int func_count;

	if (elf_version(EV_CURRENT) == EV_NONE) {
		warnx("elf_version: %s", elf_errmsg(-1));
		return;
	}

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		warn("open %s", path);
		return;
	}

	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		warnx("elf_begin: %s: %s", path, elf_errmsg(-1));
		close(fd);
		return;
	}

	if (gelf_getehdr(elf, &ehdr) == NULL)
		goto done;

	if (elf_getphdrnum(elf, &phdrnum) != 0)
		goto done;

	/* Find base vaddr for slide computation. */
	slide = 0;
	load_addr = record_addr;
	if (has_load_addr &&
	    elf_effective_load_addr(elf, load_type, record_addr,
	    &load_addr) == 0 &&
	    elf_base_vaddr(elf, &base_vaddr) == 0)
		slide = (int64_t)load_addr - (int64_t)base_vaddr;

	printf("%s", path);
	if (has_load_addr)
		printf("  @ 0x%lx", (unsigned long)load_addr);
	printf("\n");

	/* Show text segments. */
	for (i = 0; i < phdrnum; i++) {
		if (gelf_getphdr(elf, (int)i, &phdr) == NULL)
			continue;
		if (phdr.p_type != PT_LOAD)
			continue;
		if (!(phdr.p_flags & PF_X))
			continue;

		printf("  Text: 0x%lx +0x%lx (%lu bytes)",
		    (unsigned long)(phdr.p_vaddr + slide),
		    (unsigned long)phdr.p_filesz,
		    (unsigned long)phdr.p_filesz);
		if (!has_load_addr)
			printf("  [ELF offset: 0x%lx]",
			    (unsigned long)phdr.p_offset);
		printf("\n");
	}

	/* Count function symbols and note which table they came from. */
	func_count = 0;
	symtab_type = elf_preferred_symtab_type(elf);
	scn = NULL;
	while ((scn = elf_nextscn(elf, scn)) != NULL) {
		if (gelf_getshdr(scn, &shdr) == NULL)
			continue;
		if (shdr.sh_type != symtab_type)
			continue;
		if (shdr.sh_entsize == 0)
			continue;

		data = NULL;
		while ((data = elf_getdata(scn, data)) != NULL) {
			nsyms = data->d_size / shdr.sh_entsize;
			for (i = 0; i < nsyms; i++) {
				if (gelf_getsym(data, (int)i, &sym) ==
				    NULL)
					continue;
				if (GELF_ST_TYPE(sym.st_info) != STT_FUNC)
					continue;
				if (sym.st_value == 0)
					continue;
				func_count++;
			}
		}
	}

	printf("  Functions: %d", func_count);
	if (func_count > 0)
		printf(" (from %s)\n",
		    symtab_type == SHT_SYMTAB ? ".symtab" : ".dynsym");
	else
		printf("\n");

	/* Print first 50 functions sorted by address. */
	if (func_count > 0) {
		struct sym_table st;
		int shown, max_show;

		sym_table_init(&st);

		scn = NULL;
		while ((scn = elf_nextscn(elf, scn)) != NULL) {
			if (gelf_getshdr(scn, &shdr) == NULL)
				continue;
			if (shdr.sh_type != symtab_type)
				continue;
			if (shdr.sh_entsize == 0)
				continue;

			data = NULL;
			while ((data = elf_getdata(scn, data)) != NULL) {
				nsyms = data->d_size / shdr.sh_entsize;
				for (i = 0; i < nsyms; i++) {
					if (gelf_getsym(data, (int)i,
					    &sym) == NULL)
						continue;
					if (GELF_ST_TYPE(sym.st_info) !=
					    STT_FUNC)
						continue;
					if (sym.st_value == 0)
						continue;

					name = elf_strptr(elf,
					    shdr.sh_link, sym.st_name);
					sym_table_add(&st,
					    sym.st_value + slide,
					    sym.st_size, name, "");
				}
			}
		}

		sym_table_sort(&st);

		max_show = func_count > 50 ? 50 : func_count;
		for (shown = 0; shown < max_show && shown < st.count;
		    shown++) {
			printf("    0x%012lx  %s",
			    (unsigned long)st.entries[shown].addr,
			    st.entries[shown].name);
			if (st.entries[shown].size > 0)
				printf(" (%lu bytes)",
				    (unsigned long)st.entries[shown].size);
			printf("\n");
		}
		if (func_count > max_show)
			printf("    ... and %d more\n",
			    func_count - max_show);

		sym_table_free(&st);
	}

done:
	elf_end(elf);
	close(fd);
}

/* ------------------------------------------------------------------ */
/* /proc/<pid>/map parsing                                             */
/* ------------------------------------------------------------------ */

static int
info_pid(pid_t pid)
{
	char mappath[64];
	char line[4096];
	FILE *fp;
	char path[MAXPATHLEN];
	uint64_t start, end;
	int count;
	int i;
	char **shown;
	int nshown, shown_cap;

	snprintf(mappath, sizeof(mappath), "/proc/%d/map", (int)pid);
	fp = fopen(mappath, "r");
	if (fp == NULL) {
		warn("fopen %s (is procfs mounted?)", mappath);
		return (-1);
	}

	printf("PID %d\n\n", (int)pid);
	shown = NULL;
	nshown = 0;
	shown_cap = 0;

	/*
	 * FreeBSD /proc/<pid>/map format:
	 * start end ... prot ... path
	 * We look for entries with 'x' in prot and a path.
	 */
	count = 0;
	while (fgets(line, sizeof(line), fp) != NULL) {
		char protstr[16];

		path[0] = '\0';
		if (sscanf(line, "0x%lx 0x%lx %*d %*d %*x %15s %*d %*d "
		    "%*x %*s %*s %1023[^\n]",
		    &start, &end, protstr, path) < 4)
			continue;

		/* Only show executable mappings with a file path. */
		if (strchr(protstr, 'x') == NULL)
			continue;
		if (path[0] == '\0' || path[0] == '-')
			continue;

		/* Skip duplicates — same path already shown. */
		for (i = 0; i < nshown; i++) {
			if (strcmp(shown[i], path) == 0)
				break;
		}
		if (i != nshown)
			continue;
		if (nshown >= shown_cap) {
			int newcap = shown_cap == 0 ? 16 : shown_cap * 2;
			char **newshown = realloc(shown,
			    (size_t)newcap * sizeof(*shown));
			if (newshown == NULL)
				break;
			shown = newshown;
			shown_cap = newcap;
		}
		shown[nshown] = strdup(path);
		if (shown[nshown] == NULL)
			break;
		nshown++;

		printf("──────────────────────────────────────────\n");
		info_elf(path, start, true, HWT_RECORD_MMAP);
		printf("\n");
		count++;
	}

	fclose(fp);
	for (i = 0; i < nshown; i++)
		free(shown[i]);
	free(shown);

	if (count == 0)
		fprintf(stderr,
		    "No executable mappings found for PID %d\n", (int)pid);

	return (0);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_info(int argc, char **argv)
{
	pid_t pid;
	int ch;
	bool use_pid;

	use_pid = false;
	pid = 0;

	optind = 1;
	while ((ch = getopt(argc, argv, "p:")) != -1) {
		switch (ch) {
		case 'p':
			use_pid = true;
			pid = (pid_t)atoi(optarg);
			break;
		default:
			fprintf(stderr,
			    "usage: bsdtrace info [-p pid] [file ...]\n");
			return (1);
		}
	}
	argc -= optind;
	argv += optind;

	if (use_pid) {
		if (pid <= 0) {
			fprintf(stderr,
			    "bsdtrace info: PID must be positive\n");
			return (1);
		}
		return (info_pid(pid) == 0 ? 0 : 1);
	}

	if (argc < 1) {
		fprintf(stderr,
		    "usage: bsdtrace info [-p pid] [file ...]\n");
		return (1);
	}

	/* Static ELF analysis — no load address. */
	for (int i = 0; i < argc; i++) {
		if (i > 0)
			printf("\n");
		info_elf(argv[i], 0, false, 0);
	}

	return (0);
}
