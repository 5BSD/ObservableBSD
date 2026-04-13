/* Print every sched:::enqueue event */

sched:::enqueue
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched enqueue\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
