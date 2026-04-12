/* Print every sched:::enqueue event */

sched:::enqueue
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched enqueue", execname, pid, tid);
}
