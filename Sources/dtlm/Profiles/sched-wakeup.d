/* Print every sched:::wakeup event */

sched:::wakeup
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched wakeup", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
