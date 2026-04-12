/*
 * Thread States — Apple Instruments equivalent.
 *
 * Tracks scheduler state transitions per thread: on-cpu / off-cpu /
 * sleep / wakeup. Useful for understanding why a thread is or
 * isn't running.
 */

sched:::on-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: on-cpu cpu=%d\n", execname, pid, tid, cpu);
}

sched:::off-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: off-cpu\n", execname, pid, tid);
}

sched:::sleep
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sleep\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

sched:::wakeup
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: wakeup\n", execname, pid, tid);
}
