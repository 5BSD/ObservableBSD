/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * bptrace list — show HWT availability and backend capabilities.
 */

#include <sys/types.h>
#include <sys/sysctl.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bptrace.h"

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static int
sysctl_string(const char *name, char *buf, size_t bufsz)
{
	size_t len;

	len = bufsz;
	if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
		return (-1);
	return (0);
}

/* ------------------------------------------------------------------ */
/* Text output                                                         */
/* ------------------------------------------------------------------ */

static void
list_text(int hwt_avail, const char *backend, const char *cpu_model,
    const char *machine)
{

	printf("HWT Framework\n");
	printf("────────────────────────────────────────\n");
	printf("  /dev/hwt:       %s\n",
	    hwt_avail ? "available" : "not found (kldload hwt)");
	printf("  Backend:        %s\n",
	    backend ? backend : "none loaded");
	printf("  CPU:            %s\n", cpu_model);
	printf("  Architecture:   %s\n", machine);

	if (backend != NULL) {
		printf("\nBackend: %s\n", backend);
		printf("────────────────────────────────────────\n");

		if (strcmp(backend, "pt") == 0) {
			printf("  Type:           Intel Processor Trace\n");
			printf("  Modes:          thread, cpu\n");
			printf("  Features:       branch tracing, timing, "
			    "cycle-accurate\n");
		} else if (strcmp(backend, "coresight") == 0) {
			printf("  Type:           ARM CoreSight ETM\n");
			printf("  Modes:          thread, cpu\n");
			printf("  Features:       branch tracing, "
			    "timestamps\n");
		} else if (strcmp(backend, "spe") == 0) {
			printf("  Type:           ARM Statistical Profiling "
			    "Extension\n");
			printf("  Modes:          thread, cpu\n");
			printf("  Features:       statistical sampling, "
			    "latency, events\n");
		} else {
			printf("  Type:           unknown\n");
		}
	}

	if (!hwt_avail) {
		printf("\nTo enable HWT:\n");
		printf("  sudo kldload hwt\n");
		if (strcmp(machine, "amd64") == 0)
			printf("  sudo kldload pt\n");
		else if (strcmp(machine, "aarch64") == 0)
			printf("  sudo kldload coresight\n");
	} else if (backend == NULL) {
		printf("\nhwt.ko is loaded but no backend driver found.\n");
		if (strcmp(machine, "amd64") == 0) {
			printf("  sudo kldload pt\n");
			printf("  # If pt.ko is missing, build from "
			    "source:\n");
			printf("  # cd /usr/src/sys/modules/pt && "
			    "sudo make && sudo make install\n");
		} else if (strcmp(machine, "aarch64") == 0) {
			printf("  sudo kldload coresight  # or: "
			    "sudo kldload spe\n");
		}
	}
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
/* ------------------------------------------------------------------ */

static void
list_json(int hwt_avail, const char *backend, const char *cpu_model,
    const char *machine)
{

	printf("{\"hwt_available\":%s", hwt_avail ? "true" : "false");
	if (backend != NULL)
		printf(",\"backend\":\"%s\"", backend);
	else
		printf(",\"backend\":null");
	printf(",\"cpu_model\":\"%s\"", cpu_model);
	printf(",\"machine\":\"%s\"", machine);
	printf(",\"intel_pt\":%s",
	    (strcmp(machine, "amd64") == 0 && backend != NULL &&
	    strcmp(backend, "pt") == 0) ? "true" : "false");
	puts("}");
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

int
cmd_list(int argc, char **argv)
{
	enum bptrace_fmt fmt;
	char cpu_model[256];
	char machine[64];
	char *backend;
	int hwt_avail;
	int ch;

	fmt = FMT_TEXT;

	while ((ch = getopt(argc, argv, "f:")) != -1) {
		switch (ch) {
		case 'f':
			if (strcmp(optarg, "json") == 0)
				fmt = FMT_JSON;
			else if (strcmp(optarg, "text") == 0)
				fmt = FMT_TEXT;
			else {
				fprintf(stderr,
				    "bptrace list: unknown format '%s'\n",
				    optarg);
				return (1);
			}
			break;
		default:
			fprintf(stderr, "usage: bptrace list [-f text|json]\n");
			return (1);
		}
	}

	hwt_avail = hwt_available();
	backend = hwt_detect_backend();

	if (sysctl_string("hw.model", cpu_model, sizeof(cpu_model)) != 0)
		strlcpy(cpu_model, "unknown", sizeof(cpu_model));
	if (sysctl_string("hw.machine", machine, sizeof(machine)) != 0)
		strlcpy(machine, "unknown", sizeof(machine));

	if (fmt == FMT_JSON)
		list_json(hwt_avail, backend, cpu_model, machine);
	else
		list_text(hwt_avail, backend, cpu_model, machine);

	free(backend);
	return (0);
}
