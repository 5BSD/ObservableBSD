/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Symbol table — maps runtime addresses to function names.
 * Built from ELF .dynsym / .symtab sections using libelf/gelf.
 */

#include <sys/types.h>

#include <fcntl.h>
#include <gelf.h>
#include <libelf.h>
#include <libgen.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	SYM_INIT_CAP	256

void
sym_table_init(struct sym_table *st)
{

	memset(st, 0, sizeof(*st));
}

void
sym_table_add(struct sym_table *st, uint64_t addr, uint64_t size,
    const char *name, const char *binary, int64_t slide)
{
	struct sym_entry *e;
	struct sym_entry *newentries;

	if (name == NULL || name[0] == '\0')
		return;

	if (st->count >= st->capacity) {
		int newcap = st->capacity == 0 ? SYM_INIT_CAP :
		    st->capacity * 2;
		newentries = realloc(st->entries,
		    (size_t)newcap * sizeof(*st->entries));
		if (newentries == NULL)
			return;
		st->entries = newentries;
		st->capacity = newcap;
	}

	e = &st->entries[st->count++];
	e->addr = addr;
	e->size = size;
	e->slide = slide;
	e->name = strdup(name);
	e->binary = strdup(binary);
	if (e->name == NULL || e->binary == NULL) {
		free(e->name);
		free(e->binary);
		st->count--;
	}
}

void
sym_table_add_elf(struct sym_table *st, const char *path, int64_t slide)
{
	Elf *elf;
	Elf_Scn *scn;
	GElf_Shdr shdr;
	Elf_Data *data;
	GElf_Sym sym;
	GElf_Word symtab_type;
	const char *name, *bn;
	char *pathcopy;
	size_t nsyms;
	int fd;
	size_t i;

	if (elf_version(EV_CURRENT) == EV_NONE)
		return;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return;

	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		close(fd);
		return;
	}

	pathcopy = strdup(path);
	if (pathcopy == NULL) {
		elf_end(elf);
		close(fd);
		return;
	}
	bn = basename(pathcopy);
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

				name = elf_strptr(elf, shdr.sh_link,
				    sym.st_name);
				sym_table_add(st, sym.st_value + slide,
				    sym.st_size, name, bn, slide);
			}
		}
	}

	free(pathcopy);
	elf_end(elf);
	close(fd);
}

static int
sym_entry_cmp(const void *a, const void *b)
{
	const struct sym_entry *sa = a, *sb = b;

	if (sa->addr < sb->addr)
		return (-1);
	if (sa->addr > sb->addr)
		return (1);
	return (0);
}

void
sym_table_sort(struct sym_table *st)
{

	if (st->count > 1)
		qsort(st->entries, st->count, sizeof(*st->entries),
		    sym_entry_cmp);
}

const struct sym_entry *
sym_table_lookup(const struct sym_table *st, uint64_t ip)
{
	const struct sym_entry *entries;
	int lo, hi, mid, best;

	if (st->count == 0)
		return (NULL);

	entries = st->entries;
	lo = 0;
	hi = st->count - 1;
	best = -1;

	while (lo <= hi) {
		mid = lo + (hi - lo) / 2;
		if (entries[mid].addr <= ip) {
			best = mid;
			lo = mid + 1;
		} else {
			hi = mid - 1;
		}
	}

	if (best < 0)
		return (NULL);

	if (entries[best].size > 0) {
		if (ip >= entries[best].addr + entries[best].size)
			return (NULL);
	} else {
		if (ip - entries[best].addr > 4096)
			return (NULL);
	}

	return (&entries[best]);
}

void
sym_table_free(struct sym_table *st)
{
	int i;

	for (i = 0; i < st->count; i++) {
		free(st->entries[i].name);
		free(st->entries[i].binary);
	}
	free(st->entries);
	memset(st, 0, sizeof(*st));
}
