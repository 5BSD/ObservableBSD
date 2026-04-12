/* Print every sched:::dequeue event */

sched:::dequeue
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched dequeue", execname, pid, tid);
}
