/* Print every sched:::tick event */

sched:::tick
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched tick", execname, pid, tid);
}
