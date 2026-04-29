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
 * Both threads run long bounded loops with brief sleeps between
 * iterations to limit PT data rate and avoid triggering the pt.ko
 * switch-in GPF race.  The loops are long enough for attach tests.
 */

#include <pthread.h>
#include <pthread_np.h>
#include <unistd.h>

#define	NOINLINE	__attribute__((noinline))
#define	EARLY_MAIN_LOOPS	2000
#define	STEADY_MAIN_LOOPS	20000
#define	MAIN_WORK_ITERS		20000
#define	WORKER_WORK_ITERS	20000

static volatile int sink;
static volatile int running = 1;

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
	pthread_set_name_np(pthread_self(), "worker_thr");

	while (running) {
		sink = worker_work(WORKER_WORK_ITERS);
		usleep(100);
	}
	return (NULL);
}

int
main(void)
{
	pthread_t thr;
	int i;

	pthread_set_name_np(pthread_self(), "main_thr");

	/*
	 * Give exec-mode -T 0 a main-thread-only window before the
	 * worker exists.  This avoids relying on multi-thread context
	 * switching before the attach tests begin.
	 */
	for (i = 0; i < EARLY_MAIN_LOOPS; i++) {
		sink = main_work(MAIN_WORK_ITERS);
		usleep(100);
	}

	pthread_create(&thr, NULL, worker_entry, NULL);
	pthread_set_name_np(thr, "worker_thr");
	usleep(10000);

	/*
	 * Run long enough for attach tests while keeping each scheduled
	 * slice dominated by the test work functions rather than the sleep
	 * path.  Still bounded to avoid the pt.ko GPF race that infinite
	 * tight loops trigger.
	 */
	for (i = 0; i < STEADY_MAIN_LOOPS; i++) {
		sink = main_work(MAIN_WORK_ITERS);
		usleep(100);
	}

	running = 0;
	pthread_join(thr, NULL);

	return (0);
}
