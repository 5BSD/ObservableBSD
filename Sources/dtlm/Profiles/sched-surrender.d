/* Print every sched:::surrender event */

sched:::surrender
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched surrender", execname, pid, tid);
}
