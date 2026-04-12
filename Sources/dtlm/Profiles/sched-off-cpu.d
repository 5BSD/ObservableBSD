/* Print every sched:::off-cpu event */

sched:::off-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched off-cpu\n", execname, pid, tid);
}
