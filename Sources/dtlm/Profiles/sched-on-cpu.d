/* Print every sched:::on-cpu event */

sched:::on-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched on-cpu cpu=%d", execname, pid, tid, cpu);
}
