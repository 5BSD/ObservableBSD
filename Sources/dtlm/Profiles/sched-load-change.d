/* Print every sched:::load-change event */

sched:::load-change
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched load-change", execname, pid, tid);
}
