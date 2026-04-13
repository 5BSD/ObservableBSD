/* Print every sched:::on-cpu event */

sched:::on-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched on-cpu cpu=%d\n", execname, pid, tid, cpu);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
