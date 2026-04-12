/* Print sched cpu transition events (off-cpu / on-cpu / remain-cpu) */

sched:::off-cpu,
sched:::on-cpu,
sched:::remain-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched %s\n", execname, pid, tid, probename);
}
