/* Print every sched:::sleep event */

sched:::sleep
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched sleep\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
