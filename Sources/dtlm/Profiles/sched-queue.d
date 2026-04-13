/* Print sched runqueue events (dequeue + enqueue + load-change) */

sched:::dequeue,
sched:::enqueue,
sched:::load-change
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched %s\n", execname, pid, tid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
