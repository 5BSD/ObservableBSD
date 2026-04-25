/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ELF parsing — load executable segments into a pt_image, resolve
 * the dynamic linker via PT_INTERP, and build binary address ranges
 * for IP-to-binary fallback.
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

#include <intel-pt.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

bool
is_user_addr(uint64_t addr)
{

	if (addr == 0)
		return (false);
	if (addr >= 0x0000800000000000ULL)
		return (false);
	return (true);
}

/*
 * Find the p_vaddr of the first PT_LOAD segment in an open ELF.
 * Returns 0 on success, -1 if no PT_LOAD found.
 */
int
elf_base_vaddr(Elf *elf, uint64_t *base_out)
{
	GElf_Phdr phdr;
	size_t phdrnum;
	size_t i;

	if (elf_getphdrnum(elf, &phdrnum) != 0)
		return (-1);

	for (i = 0; i < phdrnum; i++) {
		if (gelf_getphdr(elf, (int)i, &phdr) == NULL)
			continue;
		if (phdr.p_type == PT_LOAD) {
			*base_out = phdr.p_vaddr;
			return (0);
		}
	}
	return (-1);
}

/* ------------------------------------------------------------------ */
/* Add ELF executable segments to pt_image                             */
/* ------------------------------------------------------------------ */

int
add_elf_to_image(struct pt_image *image, const char *path,
    uint64_t load_addr)
{
	Elf *elf;
	GElf_Phdr phdr;
	size_t phdrnum;
	uint64_t base_vaddr, runtime_vaddr;
	int64_t slide;
	int fd, added, err;
	size_t i;

	if (elf_version(EV_CURRENT) == EV_NONE)
		return (0);

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return (0);

	elf = elf_begin(fd, ELF_C_READ, NULL);
	if (elf == NULL) {
		close(fd);
		return (0);
	}

	if (elf_base_vaddr(elf, &base_vaddr) != 0)
		goto done;

	slide = (int64_t)load_addr - (int64_t)base_vaddr;

	added = 0;
	if (elf_getphdrnum(elf, &phdrnum) != 0)
		goto done;

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
/* PT_INTERP lookup                                                    */
/* ------------------------------------------------------------------ */

int
elf_get_interp(const char *path, char *interp, size_t interpsz)
{
	Elf *elf;
	GElf_Phdr phdr;
	size_t phdrnum;
	int fd;
	size_t i;

	if (elf_version(EV_CURRENT) == EV_NONE)
		return (-1);

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
/* Binary range tracking                                               */
/* ------------------------------------------------------------------ */

int
build_bin_ranges(const struct pt_image_info *sections, int nsections,
    struct bin_range *ranges, int maxranges)
{
	Elf *elf;
	GElf_Phdr phdr;
	size_t phdrnum;
	uint64_t base_vaddr;
	int64_t slide;
	int fd, nranges;
	size_t j;
	char interp[MAXPATHLEN];
	char *pathcopy, *bn;
	int i;

	if (elf_version(EV_CURRENT) == EV_NONE)
		return (0);

	nranges = 0;

	for (i = 0; i < nsections && nranges < maxranges; i++) {
		fd = open(sections[i].path, O_RDONLY);
		if (fd < 0)
			continue;
		elf = elf_begin(fd, ELF_C_READ, NULL);
		if (elf == NULL) {
			close(fd);
			continue;
		}

		if (elf_base_vaddr(elf, &base_vaddr) != 0) {
			elf_end(elf);
			close(fd);
			continue;
		}

		slide = (int64_t)sections[i].load_addr -
		    (int64_t)base_vaddr;

		if (elf_getphdrnum(elf, &phdrnum) == 0) {
			for (j = 0; j < phdrnum && nranges < maxranges;
			    j++) {
				if (gelf_getphdr(elf, (int)j, &phdr) == NULL)
					continue;
				if (phdr.p_type != PT_LOAD ||
				    !(phdr.p_flags & PF_X) ||
				    phdr.p_filesz == 0)
					continue;

				pathcopy = strdup(sections[i].path);
				if (pathcopy == NULL)
					continue;
				bn = basename(pathcopy);
				strlcpy(ranges[nranges].name, bn,
				    sizeof(ranges[nranges].name));
				free(pathcopy);
				ranges[nranges].lo = phdr.p_vaddr + slide;
				ranges[nranges].hi = phdr.p_vaddr + slide +
				    phdr.p_filesz;
				ranges[nranges].base =
				    sections[i].load_addr;
				nranges++;
			}
		}

		/* Handle interpreter for EXEC records. */
		if (sections[i].type == HWT_RECORD_EXECUTABLE &&
		    is_user_addr(sections[i].base_addr) &&
		    sections[i].base_addr != sections[i].load_addr) {
			if (elf_get_interp(sections[i].path,
			    interp, sizeof(interp)) == 0) {
				Elf *elf2;
				uint64_t interp_base;
				int fd2 = open(interp, O_RDONLY);
				if (fd2 >= 0) {
					elf2 = elf_begin(fd2, ELF_C_READ,
					    NULL);
					if (elf2 != NULL &&
					    elf_base_vaddr(elf2,
					    &interp_base) == 0) {
						int64_t islide =
						    (int64_t)sections[i].base_addr -
						    (int64_t)interp_base;
						size_t iphdrnum;
						if (elf_getphdrnum(elf2,
						    &iphdrnum) == 0) {
							for (j = 0;
							    j < iphdrnum &&
							    nranges < maxranges;
							    j++) {
								if (gelf_getphdr(elf2,
								    (int)j, &phdr) == NULL)
									continue;
								if (phdr.p_type != PT_LOAD ||
								    !(phdr.p_flags & PF_X) ||
								    phdr.p_filesz == 0)
									continue;
								strlcpy(ranges[nranges].name,
								    "ld-elf.so.1",
								    sizeof(ranges[nranges].name));
								ranges[nranges].lo =
								    phdr.p_vaddr + islide;
								ranges[nranges].hi =
								    phdr.p_vaddr + islide +
								    phdr.p_filesz;
								ranges[nranges].base =
								    sections[i].base_addr;
								nranges++;
							}
						}
					}
					if (elf2 != NULL)
						elf_end(elf2);
					close(fd2);
				}
			}
		}

		elf_end(elf);
		close(fd);
	}

	return (nranges);
}

const char *
find_binary_for_ip(const struct bin_range *ranges, int nranges,
    uint64_t ip, uint64_t *offset)
{
	int i;

	for (i = 0; i < nranges; i++) {
		if (ip >= ranges[i].lo && ip < ranges[i].hi) {
			*offset = ip - ranges[i].lo;
			return (ranges[i].name);
		}
	}
	return (NULL);
}
