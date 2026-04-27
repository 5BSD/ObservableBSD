/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Metadata sidecar (.meta) — save and load EXEC/MMAP/THREAD records
 * as JSONL alongside the .pt file for offline decode.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/hwt.h>

#include <err.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* Writer                                                              */
/* ------------------------------------------------------------------ */

struct meta_writer {
	FILE	*fp;
};

struct meta_writer *
meta_writer_open(const char *path)
{
	struct meta_writer *mw;

	mw = calloc(1, sizeof(*mw));
	if (mw == NULL)
		return (NULL);

	mw->fp = fopen(path, "w");
	if (mw->fp == NULL) {
		warn("fopen %s", path);
		free(mw);
		return (NULL);
	}
	/* Line-buffer so each JSONL record is flushed immediately.
	 * Without this, SIGPIPE or Ctrl-C loses all buffered metadata. */
	setvbuf(mw->fp, NULL, _IOLBF, 0);
	return (mw);
}

void
meta_writer_header(struct meta_writer *mw, pid_t pid, int tid)
{

	if (mw == NULL || mw->fp == NULL)
		return;
	fprintf(mw->fp,
	    "{\"type\":\"header\",\"pid\":%d,\"tid\":%d}\n",
	    (int)pid, tid);
}

void
meta_writer_record(struct meta_writer *mw, const struct bsdtrace_record *rec)
{

	if (mw == NULL || mw->fp == NULL)
		return;

	switch (rec->type) {
	case HWT_RECORD_EXECUTABLE:
		fprintf(mw->fp,
		    "{\"type\":\"exec\",\"path\":\"%s\","
		    "\"addr\":\"0x%lx\",\"base\":\"0x%lx\"}\n",
		    rec->fullpath,
		    (unsigned long)rec->addr,
		    (unsigned long)rec->baseaddr);
		break;
	case HWT_RECORD_MMAP:
		fprintf(mw->fp,
		    "{\"type\":\"mmap\",\"path\":\"%s\","
		    "\"addr\":\"0x%lx\",\"base\":\"0x%lx\"}\n",
		    rec->fullpath,
		    (unsigned long)rec->addr,
		    (unsigned long)rec->baseaddr);
		break;
	case HWT_RECORD_THREAD_CREATE:
		fprintf(mw->fp,
		    "{\"type\":\"thread_create\",\"tid\":%d}\n",
		    rec->thread_id);
		break;
	case HWT_RECORD_THREAD_SET_NAME:
		fprintf(mw->fp,
		    "{\"type\":\"thread_name\",\"tid\":%d}\n",
		    rec->thread_id);
		break;
	default:
		break;
	}
}

void
meta_writer_close(struct meta_writer *mw)
{

	if (mw == NULL)
		return;
	if (mw->fp != NULL)
		fclose(mw->fp);
	free(mw);
}

/* ------------------------------------------------------------------ */
/* Reader                                                              */
/* ------------------------------------------------------------------ */

int
meta_read_tid(const char *path)
{
	FILE *fp;
	char line[256];
	int tid;

	fp = fopen(path, "r");
	if (fp == NULL)
		return (-1);

	/* The header is the first line: {"type":"header","pid":N,"tid":N} */
	if (fgets(line, sizeof(line), fp) != NULL &&
	    sscanf(line, "{\"type\":\"header\",\"pid\":%*d,\"tid\":%d}",
	    &tid) == 1) {
		fclose(fp);
		return (tid);
	}

	fclose(fp);
	return (-1);
}

int
meta_read_sections(const char *path,
    struct pt_image_info **sections_out, int *nsections_out)
{
	FILE *fp;
	struct pt_image_info *sections;
	struct pt_image_info *newsections;
	int nsections, capacity;
	char line[4096];
	char type[32], fpath[MAXPATHLEN];
	uint64_t addr, base;

	fp = fopen(path, "r");
	if (fp == NULL) {
		warn("fopen %s", path);
		return (-1);
	}

	sections = NULL;
	nsections = 0;
	capacity = 0;

	while (fgets(line, sizeof(line), fp) != NULL) {
		type[0] = '\0';
		fpath[0] = '\0';
		addr = 0;
		base = 0;

		/*
		 * Parse JSONL lines for exec/mmap records.
		 * Simple sscanf — the JSON is machine-generated with
		 * no special characters in paths.
		 */
		if (sscanf(line,
		    "{\"type\":\"%31[^\"]\",\"path\":\"%1023[^\"]\","
		    "\"addr\":\"0x%lx\",\"base\":\"0x%lx\"}",
		    type, fpath, &addr, &base) == 4) {
			if (strcmp(type, "exec") != 0 &&
			    strcmp(type, "mmap") != 0)
				continue;

			/*
			 * Keep all records — section_should_use() handles
			 * deduplication at decode time, picking the lowest-
			 * address MMAP per path rather than first-wins.
			 */
			if (nsections >= capacity) {
				capacity = capacity == 0 ? 16 :
				    capacity * 2;
				newsections = realloc(sections,
				    (size_t)capacity *
				    sizeof(*sections));
				if (newsections == NULL) {
					fclose(fp);
					free(sections);
					return (-1);
				}
				sections = newsections;
			}

			strlcpy(sections[nsections].path, fpath,
			    sizeof(sections[nsections].path));
			sections[nsections].load_addr = addr;
			sections[nsections].base_addr = base;
			sections[nsections].type =
			    strcmp(type, "exec") == 0 ?
			    HWT_RECORD_EXECUTABLE : HWT_RECORD_MMAP;
			nsections++;
		}
	}

	fclose(fp);
	*sections_out = sections;
	*nsections_out = nsections;
	return (0);
}
