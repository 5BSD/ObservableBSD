/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ptwprog -- test program for PTWRITE trace markers.
 *
 * Emits three PTWRITE markers with known payloads so the test suite
 * can verify that bsdtrace -W captures and decodes them.
 *
 * Must be traced with:  bsdtrace exec -W -- ./ptwprog
 *
 * Compile from the repo root:
 *   cc -O0 -I Sources/bsdtrace -o ptwprog Tests/bsdtrace/ptwprog/main.c
 */

#include <unistd.h>
#include "bsdtrace_ptwrite.h"

int
main(void)
{

	bsdtrace_ptwrite(0x123456789abcdef0ULL);
	bsdtrace_ptwrite32(0x89abcdefU);
	bsdtrace_ptwrite(0x0fedcba987654321ULL);

	/* Brief delay so PT buffer flushes before exit. */
	usleep(10000);

	return (0);
}
