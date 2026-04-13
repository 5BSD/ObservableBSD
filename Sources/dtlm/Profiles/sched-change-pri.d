/* Print every sched:::change-pri event */

sched:::change-pri
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched change-pri\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
