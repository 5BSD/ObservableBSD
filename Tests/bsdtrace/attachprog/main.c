/*-
 * Copyright (c) 2026 Kory Heard
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * attachprog — long-running trace target for bsdtrace attach tests.
 *
 * The program stays alive until signalled, continuously executes
 * predictable control-flow in named functions, and periodically
 * performs an executable file-backed mmap to exercise HWT MMAP hooks
 * after bsdtrace has already attached.
 */

#include <sys/mman.h>
#include <sys/param.h>

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#define	NOINLINE	__attribute__((noinline))

static volatile sig_atomic_t stop_flag;
static volatile int sink;

static void
signal_handler(int sig __unused)
{

	stop_flag = 1;
}

NOINLINE int
attach_leaf(int x)
{

	return (x + 1);
}

NOINLINE int
attach_branch(int x)
{

	if ((x & 1) == 0)
		return (attach_leaf(x));
	return (x - 1);
}

NOINLINE int
attach_loop(int n)
{
	int i, sum;

	sum = 0;
	for (i = 0; i < n; i++)
		sum += attach_branch(i);
	return (sum);
}

NOINLINE void
attach_exec_mmap(void)
{
	void *map;
	volatile unsigned char *p;
	int fd;

	fd = open("/bin/echo", O_RDONLY);
	if (fd < 0)
		return;

	map = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_EXEC, MAP_PRIVATE,
	    fd, 0);
	if (map != MAP_FAILED) {
		p = map;
		sink += p[0];
		munmap(map, PAGE_SIZE);
	}

	close(fd);
}

int
main(void)
{
	int iter;

	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);
	signal(SIGHUP, signal_handler);

	iter = 0;
	while (!stop_flag) {
		sink = attach_loop(128);
		if ((iter % 250) == 0)
			attach_exec_mmap();
		iter++;
		usleep(1000);
	}

	return (0);
}
