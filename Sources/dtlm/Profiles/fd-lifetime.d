/*
 * File descriptor lifetime — track open/close pairs.
 *
 * Records when FDs are created (open, socket, pipe, dup) and
 * when they're closed. At exit, reports FD creation sites
 * that were never closed — potential FD leaks.
 */

syscall::open:return,
syscall::openat:return
/arg1 >= 0 /* @dtlm-predicate-and *//
{
    fd_open_ts[pid, arg1] = timestamp;
    @fd_opens[execname, probefunc] = count();
}

syscall::socket:return
/arg1 >= 0 /* @dtlm-predicate-and *//
{
    fd_open_ts[pid, arg1] = timestamp;
    @fd_opens[execname, "socket"] = count();
}

syscall::pipe:return
/arg0 == 0 /* @dtlm-predicate-and *//
{
    @fd_opens[execname, "pipe"] = count();
}

syscall::dup:return,
syscall::dup2:return
/arg1 >= 0 /* @dtlm-predicate-and *//
{
    fd_open_ts[pid, arg1] = timestamp;
    @fd_opens[execname, probefunc] = count();
}

syscall::close:entry
/* @dtlm-predicate */
{
    @fd_closes[execname] = count();
    fd_open_ts[pid, arg0] = 0;
}

dtrace:::END
{
    printf("\n--- FD opens by process/source ---\n");
    printa("%-20s %-14s %@d\n", @fd_opens);
    printf("\n--- FD closes by process ---\n");
    printa("%-20s %@d\n", @fd_closes);
}
