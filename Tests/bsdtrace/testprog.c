/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * testprog — deterministic test binary for bsdtrace decoder validation.
 *
 * Every function is noinline to guarantee CALL/RETURN events in the
 * PT trace.  The program exercises:
 *
 *   - Direct calls and returns      (leaf_add, leaf_mul)
 *   - Nested call chains            (nested_inner -> leaf_add,
 *                                    nested_outer -> nested_inner)
 *   - Conditional branches (CJMP)   (branch_test: if/else)
 *   - Loops (CJMP)                  (loop_test: for loop)
 *   - Syscalls (far call)           (do_write: write(2))
 *
 * Compile:  cc -O0 -o testprog testprog.c
 *
 * Expected decode output should contain CALL/RETURN events for all
 * named functions, CJMP events from branch_test and loop_test, and
 * SYSCALL events from do_write.
 */

#include <unistd.h>

/* Prevent the compiler from inlining — each function must produce
 * its own CALL/RETURN pair in the PT trace. */
#define	NOINLINE	__attribute__((noinline))

/* Volatile sink — prevents the compiler from optimising away calls
 * whose return values would otherwise be unused. */
static volatile int sink;

/*
 * Leaf functions — simple CALL + RETURN, no further calls.
 */
NOINLINE int
leaf_add(int a, int b)
{

	return (a + b);
}

NOINLINE int
leaf_mul(int a, int b)
{

	return (a * b);
}

/*
 * Nested call chain — two levels deep.
 *   nested_outer -> nested_inner -> leaf_add
 */
NOINLINE int
nested_inner(int x)
{

	return (leaf_add(x, 1));
}

NOINLINE int
nested_outer(int x)
{
	int a, b;

	a = nested_inner(x);
	b = nested_inner(a);
	return (b);
}

/*
 * Conditional branch — exercises CJMP (taken / not-taken).
 *   x > 0  -> leaf_add path
 *   x <= 0 -> leaf_mul path
 */
NOINLINE int
branch_test(int x)
{

	if (x > 0)
		return (leaf_add(x, 10));
	else
		return (leaf_mul(x, -1));
}

/*
 * Loop — exercises repeated CJMP at the loop-back edge.
 */
NOINLINE int
loop_test(int n)
{
	int sum, i;

	sum = 0;
	for (i = 0; i < n; i++)
		sum = leaf_add(sum, i);
	return (sum);
}

/*
 * Syscall — write(2) produces a SYSCALL (far call) event.
 * Output goes to stdout so the test script can verify it.
 */
NOINLINE void
do_write(void)
{
	const char msg[] = "bsdtrace-testprog\n";

	(void)write(STDOUT_FILENO, msg, sizeof(msg) - 1);
}

int
main(int argc, char **argv)
{

	(void)argv;

	/* Direct calls and returns. */
	sink = leaf_add(1, 2);
	sink = leaf_mul(3, 4);

	/* Nested call chain. */
	sink = nested_outer(5);

	/* Conditional branches — exercise both paths. */
	sink = branch_test(argc);	/* argc >= 1 → leaf_add path */
	sink = branch_test(-1);		/* negative  → leaf_mul path */

	/* Loop — 10 iterations of CJMP + CALL leaf_add. */
	sink = loop_test(10);

	/* Syscall. */
	do_write();

	/* Brief delay so PT buffer flushes before exit. */
	usleep(10000);

	return (0);
}
