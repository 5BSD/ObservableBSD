/*
 * System Trace — Apple Instruments equivalent.
 *
 * The kitchen-sink view: every syscall, every proc lifecycle event,
 * every sched on-cpu / off-cpu transition, every signal delivery,
 * every page fault. Use with --execname or --pid to scope it to
 * one process — you'll regret leaving it system-wide.
 */

syscall:::entry
/* @dtlm-predicate */
{
    printf("%s[%d]: syscall %s entry", execname, pid, probefunc);
    /* @dtlm-ustack */
}

syscall:::return
/* @dtlm-predicate */
{
    printf("%s[%d]: syscall %s return = %d", execname, pid, probefunc, (int)arg1);
}

proc:::create,
proc:::exec-success,
proc:::exec-failure,
proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: proc %s", execname, pid, probename);
    /* @dtlm-ustack */
}

proc:::signal-send
/* @dtlm-predicate */
{
    printf("%s[%d]: proc signal-send sig=%d", execname, pid, (int)arg2);
}
