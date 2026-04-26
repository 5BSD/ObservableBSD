/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bsdtrace decode — offline re-decode a saved .pt + .meta file pair.
 *
 * Reads the raw PT data and binary mapping metadata, rebuilds the
 * libipt image, and decodes with optional software filters.
 * Enables the "trace once, analyze many times" workflow.
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_decode(int argc, char **argv)
{
	struct pt_image_info *sections;
	enum bsdtrace_fmt fmt;
	struct stat sb;
	const char *pt_path;
	char meta_path[MAXPATHLEN] = "";
	void *buf;
	int rc;
	int nsections;
	int fd;
	int ch;

	fmt = FMT_TEXT;
	sections = NULL;
	nsections = 0;

	optind = 1;
	while ((ch = getopt(argc, argv, "f:m:")) != -1) {
		switch (ch) {
		case 'f':
			if (strcmp(optarg, "json") == 0)
				fmt = FMT_JSON;
			else if (strcmp(optarg, "text") == 0)
				fmt = FMT_TEXT;
			else {
				fprintf(stderr,
				    "bsdtrace decode: unknown format '%s'\n",
				    optarg);
				return (1);
			}
			break;
		case 'm':
			/* Explicit .meta file path. */
			if (meta_read_sections(optarg,
			    &sections, &nsections) != 0)
				return (1);
			break;
		default:
			fprintf(stderr,
			    "usage: bsdtrace decode [-f text|json] "
			    "[-m meta] file.pt\n");
			return (1);
		}
	}
	argc -= optind;
	argv += optind;

	if (argc < 1) {
		fprintf(stderr,
		    "bsdtrace decode: .pt file required\n");
		return (1);
	}
	pt_path = argv[0];

	/* If no explicit -m, derive .meta path from .pt path. */
	if (sections == NULL) {
		size_t len = strlen(pt_path);

		if (len > 3 && strcmp(pt_path + len - 3, ".pt") == 0) {
			snprintf(meta_path, sizeof(meta_path),
			    "%.*s.meta", (int)(len - 3), pt_path);
		} else {
			snprintf(meta_path, sizeof(meta_path),
			    "%s.meta", pt_path);
		}

		if (meta_read_sections(meta_path,
		    &sections, &nsections) != 0) {
			fprintf(stderr,
			    "bsdtrace decode: cannot read metadata "
			    "from %s\n"
			    "  Use -m to specify the .meta file path\n",
			    meta_path);
			return (1);
		}
	}

	/* mmap the .pt file. */
	fd = open(pt_path, O_RDONLY);
	if (fd < 0) {
		warn("open %s", pt_path);
		free(sections);
		return (1);
	}

	if (fstat(fd, &sb) != 0) {
		warn("fstat %s", pt_path);
		close(fd);
		free(sections);
		return (1);
	}

	if (sb.st_size == 0) {
		warnx("%s: empty file", pt_path);
		close(fd);
		free(sections);
		return (1);
	}

	buf = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (buf == MAP_FAILED) {
		warn("mmap %s", pt_path);
		free(sections);
		return (1);
	}

	/* Line-buffer stdout — see cmd_trace.c comment. */
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (fmt == FMT_TEXT)
		fprintf(stderr,
		    "Decoding %s (%lld bytes, %d binaries from %s)\n",
		    pt_path, (long long)sb.st_size, nsections,
		    meta_path);

	rc = decode_pt_insn(buf, (size_t)sb.st_size, sections, nsections,
	    fmt);

	munmap(buf, sb.st_size);
	free(sections);
	return (rc == 0 ? 0 : 1);
}
