/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * dwarf.c — DWARF .debug_line resolution for source-line attribution.
 *
 * Resolves instruction addresses to source file:line using libdwarf.
 * Caches per-binary Dwarf_Debug handles to avoid re-parsing.
 */

#include <sys/types.h>
#include <sys/param.h>

#include <dwarf.h>
#include <libdwarf.h>
#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

#define	MAX_DWARF_CACHES	32

struct dwarf_cache {
	char		path[MAXPATHLEN];
	Dwarf_Debug	dbg;
	int		fd;
	int64_t		slide;
};

static struct dwarf_cache caches[MAX_DWARF_CACHES];
static int ncaches;

struct dwarf_cache *
dwarf_cache_open(const char *binary_path, int64_t slide)
{
	struct dwarf_cache *dc;
	Dwarf_Error err;
	int i, fd;

	for (i = 0; i < ncaches; i++) {
		if (strcmp(caches[i].path, binary_path) == 0)
			return (&caches[i]);
	}

	if (ncaches >= MAX_DWARF_CACHES)
		return (NULL);

	fd = open(binary_path, O_RDONLY);
	if (fd < 0)
		return (NULL);

	dc = &caches[ncaches];
	memset(dc, 0, sizeof(*dc));
	strlcpy(dc->path, binary_path, sizeof(dc->path));
	dc->fd = fd;
	dc->slide = slide;

	if (dwarf_init(fd, DW_DLC_READ, NULL, NULL,
	    &dc->dbg, &err) != DW_DLV_OK) {
		close(fd);
		return (NULL);
	}

	ncaches++;
	return (dc);
}

int
dwarf_addr_to_line(struct dwarf_cache *dc, uint64_t addr,
    char *file_out, size_t filesz, int *line_out)
{
	Dwarf_Line *lines;
	Dwarf_Signed nlines;
	Dwarf_Unsigned cu_header_length, next_cu_offset;
	Dwarf_Half version_stamp, address_size, length_size, extension_size;
	Dwarf_Off abbrev_offset;
	Dwarf_Sig8 sig;
	Dwarf_Die cu_die;
	Dwarf_Error err;
	Dwarf_Addr lineaddr;
	Dwarf_Unsigned lineno;
	char *src;
	uint64_t file_addr;
	int i, rc;
	Dwarf_Addr global_best_addr;
	char global_best_file[MAXPATHLEN];
	int global_best_line;
	bool found;

	if (dc == NULL || dc->dbg == NULL)
		return (-1);

	file_addr = addr - dc->slide;
	found = false;
	global_best_addr = 0;
	global_best_file[0] = '\0';
	global_best_line = 0;

	/* Rewind the CU iterator. */
	while (dwarf_next_cu_header_c(dc->dbg, 1,
	    &cu_header_length, &version_stamp, &abbrev_offset,
	    &address_size, &length_size, &extension_size,
	    &sig, &next_cu_offset, NULL, &err) == DW_DLV_OK)
		;

	/* Search all CUs for the best matching line. */
	while ((rc = dwarf_next_cu_header_c(dc->dbg, 1,
	    &cu_header_length, &version_stamp, &abbrev_offset,
	    &address_size, &length_size, &extension_size,
	    &sig, &next_cu_offset, NULL, &err)) == DW_DLV_OK) {

		if (dwarf_siblingof_b(dc->dbg, NULL, &cu_die, 1,
		    &err) != DW_DLV_OK)
			continue;

		if (dwarf_srclines(cu_die, &lines, &nlines,
		    &err) != DW_DLV_OK) {
			dwarf_dealloc(dc->dbg, cu_die, DW_DLA_DIE);
			continue;
		}

		for (i = 0; i < nlines; i++) {
			if (dwarf_lineaddr(lines[i], &lineaddr,
			    &err) != DW_DLV_OK)
				continue;
			if (lineaddr <= file_addr &&
			    lineaddr > global_best_addr) {
				global_best_addr = lineaddr;
				if (dwarf_linesrc(lines[i], &src,
				    &err) == DW_DLV_OK) {
					strlcpy(global_best_file, src,
					    sizeof(global_best_file));
					dwarf_dealloc(dc->dbg, src,
					    DW_DLA_STRING);
				}
				if (dwarf_lineno(lines[i], &lineno,
				    &err) == DW_DLV_OK)
					global_best_line = (int)lineno;
				found = true;
			}
		}

		dwarf_srclines_dealloc(dc->dbg, lines, nlines);
		dwarf_dealloc(dc->dbg, cu_die, DW_DLA_DIE);
	}

	if (found && (file_addr - global_best_addr) < 64) {
		strlcpy(file_out, global_best_file, filesz);
		*line_out = global_best_line;
		return (0);
	}

	return (-1);
}

void
dwarf_cache_close_all(void)
{
	Dwarf_Error err;
	int i;

	for (i = 0; i < ncaches; i++) {
		if (caches[i].dbg != NULL)
			dwarf_finish(caches[i].dbg, &err);
		if (caches[i].fd >= 0)
			close(caches[i].fd);
	}
	ncaches = 0;
}
