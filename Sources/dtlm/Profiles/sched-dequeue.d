/* Print every sched:::dequeue event */

sched:::dequeue
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched dequeue\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
