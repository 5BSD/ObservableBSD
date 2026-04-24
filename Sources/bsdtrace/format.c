/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Output formatting — text and JSON record renderers.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/hwt.h>

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "bsdtrace.h"

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static void
print_timestamp(void)
{
	struct timespec ts;
	struct tm tm;

	clock_gettime(CLOCK_REALTIME, &ts);
	gmtime_r(&ts.tv_sec, &tm);
	printf("%02d:%02d:%02d.%06ld",
	    tm.tm_hour, tm.tm_min, tm.tm_sec,
	    ts.tv_nsec / 1000);
}

static void
print_iso8601(FILE *fp)
{
	struct timespec ts;
	struct tm tm;

	clock_gettime(CLOCK_REALTIME, &ts);
	gmtime_r(&ts.tv_sec, &tm);
	fprintf(fp, "%04d-%02d-%02dT%02d:%02d:%02dZ",
	    tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
	    tm.tm_hour, tm.tm_min, tm.tm_sec);
}

/*
 * Emit a JSON-safe string (RFC 8259).
 * Escapes: \ " and control characters < 0x20.
 */
static void
json_string(FILE *fp, const char *s)
{

	fputc('"', fp);
	for (; *s != '\0'; s++) {
		unsigned char c = (unsigned char)*s;

		switch (c) {
		case '"':
			fputs("\\\"", fp);
			break;
		case '\\':
			fputs("\\\\", fp);
			break;
		case '\b':
			fputs("\\b", fp);
			break;
		case '\f':
			fputs("\\f", fp);
			break;
		case '\n':
			fputs("\\n", fp);
			break;
		case '\r':
			fputs("\\r", fp);
			break;
		case '\t':
			fputs("\\t", fp);
			break;
		default:
			if (c < 0x20)
				fprintf(fp, "\\u%04x", c);
			else
				fputc(c, fp);
			break;
		}
	}
	fputc('"', fp);
}

static const char *
record_type_name(enum hwt_record_type t)
{

	switch (t) {
	case HWT_RECORD_MMAP:		return ("mmap");
	case HWT_RECORD_MUNMAP:		return ("munmap");
	case HWT_RECORD_EXECUTABLE:	return ("executable");
	case HWT_RECORD_KERNEL:		return ("kernel");
	case HWT_RECORD_THREAD_CREATE:	return ("thread_create");
	case HWT_RECORD_THREAD_SET_NAME: return ("thread_set_name");
	case HWT_RECORD_BUFFER:		return ("buffer");
	default:			return ("unknown");
	}
}

/* ------------------------------------------------------------------ */
/* Text output                                                         */
/* ------------------------------------------------------------------ */

void
fmt_record_text(const struct bsdtrace_record *rec, pid_t pid)
{

	print_timestamp();

	switch (rec->type) {
	case HWT_RECORD_EXECUTABLE:
		printf("  EXEC  pid=%d  %s  addr=0x%lx  base=0x%lx\n",
		    (int)pid,
		    rec->fullpath[0] ? rec->fullpath : "<unknown>",
		    (unsigned long)rec->addr,
		    (unsigned long)rec->baseaddr);
		break;

	case HWT_RECORD_MMAP:
		printf("  MMAP  pid=%d  %s  addr=0x%lx  base=0x%lx\n",
		    (int)pid,
		    rec->fullpath[0] ? rec->fullpath : "<anon>",
		    (unsigned long)rec->addr,
		    (unsigned long)rec->baseaddr);
		break;

	case HWT_RECORD_MUNMAP:
		printf("  MUNMAP  pid=%d", (int)pid);
		if (rec->addr != 0)
			printf("  addr=0x%lx", (unsigned long)rec->addr);
		putchar('\n');
		break;

	case HWT_RECORD_KERNEL:
		printf("  KERNEL  %s  addr=0x%lx  base=0x%lx\n",
		    rec->fullpath[0] ? rec->fullpath : "<kernel>",
		    (unsigned long)rec->addr,
		    (unsigned long)rec->baseaddr);
		break;

	case HWT_RECORD_THREAD_CREATE:
		printf("  THREAD_CREATE  pid=%d  tid=%d\n",
		    (int)pid, rec->thread_id);
		break;

	case HWT_RECORD_THREAD_SET_NAME:
		printf("  THREAD_NAME  pid=%d  tid=%d\n",
		    (int)pid, rec->thread_id);
		break;

	case HWT_RECORD_BUFFER:
		printf("  BUFFER  buf_id=%d  page=%d  offset=0x%lx\n",
		    rec->buf_id, rec->curpage,
		    (unsigned long)rec->offset);
		break;

	default:
		printf("  UNKNOWN  type=%d\n", rec->type);
		break;
	}
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
/* ------------------------------------------------------------------ */

void
fmt_record_json(const struct bsdtrace_record *rec, pid_t pid)
{

	printf("{\"timestamp\":\"");
	print_iso8601(stdout);
	printf("\",\"kind\":");
	json_string(stdout, record_type_name(rec->type));
	printf(",\"pid\":%d", (int)pid);

	switch (rec->type) {
	case HWT_RECORD_MMAP:
	case HWT_RECORD_EXECUTABLE:
	case HWT_RECORD_KERNEL:
		if (rec->fullpath[0]) {
			printf(",\"path\":");
			json_string(stdout, rec->fullpath);
		}
		printf(",\"address\":\"0x%lx\"", (unsigned long)rec->addr);
		printf(",\"base_address\":\"0x%lx\"",
		    (unsigned long)rec->baseaddr);
		break;

	case HWT_RECORD_MUNMAP:
		if (rec->addr != 0)
			printf(",\"address\":\"0x%lx\"",
			    (unsigned long)rec->addr);
		break;

	case HWT_RECORD_THREAD_CREATE:
	case HWT_RECORD_THREAD_SET_NAME:
		printf(",\"thread_id\":%d", rec->thread_id);
		break;

	case HWT_RECORD_BUFFER:
		printf(",\"buf_id\":%d,\"page\":%d,\"offset\":%lu",
		    rec->buf_id, rec->curpage,
		    (unsigned long)rec->offset);
		break;

	default:
		break;
	}

	puts("}");
}
