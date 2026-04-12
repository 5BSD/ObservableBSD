/* Print every sched:::lend-pri event */

sched:::lend-pri
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched lend-pri", execname, pid, tid);
}
