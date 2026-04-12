/* Print sched priority change events (change-pri + lend-pri) */

sched:::change-pri,
sched:::lend-pri
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched %s\n", execname, pid, tid, probename);
}
