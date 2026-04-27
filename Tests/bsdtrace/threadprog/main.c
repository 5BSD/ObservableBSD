/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * threadprog — multi-threaded test binary for bsdtrace thread selection.
 *
 * The main thread calls main_work() in a loop.
 * A worker thread calls worker_work() in a loop.
 * Each function group is noinline with distinct names so the test
 * suite can verify that -T 0 traces only main_* functions and
 * -T 1 traces only worker_* functions.
 *
 * Both threads loop indefinitely.  The test suite kills the process
 * when done (via bsdtrace -t timeout or explicit kill).
 */

#include <pthread.h>
#include <unistd.h>

#define	NOINLINE	__attribute__((noinline))

static volatile int sink;

/* --- Main thread functions --- */

NOINLINE int
main_leaf(int x)
{

	return (x + 3);
}

NOINLINE int
main_work(int n)
{
	int i, s = 0;

	for (i = 0; i < n; i++)
		s = main_leaf(s);
	return (s);
}

/* --- Worker thread functions --- */

NOINLINE int
worker_leaf(int x)
{

	return (x + 7);
}

NOINLINE int
worker_work(int n)
{
	int i, s = 0;

	for (i = 0; i < n; i++)
		s = worker_leaf(s);
	return (s);
}

static void *
worker_entry(void *arg __unused)
{

	for (;;)
		sink = worker_work(200);
	return (NULL);
}

int
main(void)
{
	pthread_t thr;

	pthread_create(&thr, NULL, worker_entry, NULL);

	/* Give the worker time to start. */
	usleep(10000);

	/* Loop forever — bsdtrace kills us via timeout or the test
	 * script kills us after tracing. */
	for (;;)
		sink = main_work(100);

	/* NOTREACHED */
	return (0);
}
