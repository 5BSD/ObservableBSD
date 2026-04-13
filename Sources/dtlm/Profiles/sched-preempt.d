/* Print every sched:::preempt event */

sched:::preempt
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched preempt\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
