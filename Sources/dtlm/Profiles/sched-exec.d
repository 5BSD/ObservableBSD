/* Print sched sleep and wakeup transitions */

sched:::sleep,
sched:::wakeup
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched %s\n", execname, pid, tid, probename);
}
