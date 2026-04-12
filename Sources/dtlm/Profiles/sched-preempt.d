/* Print every sched:::preempt event */

sched:::preempt
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched preempt", execname, pid, tid);
}
