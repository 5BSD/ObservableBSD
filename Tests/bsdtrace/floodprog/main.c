/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * floodprog — high-volume trace workload for PT buffer wrap tests.
 *
 * The goal is not exact symbol/count validation.  The goal is to
 * generate enough deterministic control flow that a deliberately tiny
 * PT buffer will wrap, allowing the test suite to verify that
 * bsdtrace reports the wrap condition instead of silently pretending
 * the trace is complete.
 */

#include <unistd.h>

#define	NOINLINE	__attribute__((noinline))

static volatile int sink;

NOINLINE int
flood_leaf(int x)
{

	return (x + 1);
}

NOINLINE int
flood_branch(int x)
{

	if ((x & 1) == 0)
		return (flood_leaf(x));
	return (x - 1);
}

NOINLINE int
flood_loop(int n)
{
	int i, sum;

	sum = 0;
	for (i = 0; i < n; i++)
		sum += flood_branch(i);
	return (sum);
}

int
main(void)
{
	int i;

	for (i = 0; i < 20000; i++)
		sink = flood_loop(128);

	/* Keep the process alive briefly so teardown is not instantaneous. */
	usleep(10000);
	return (0);
}
