/* Print every sched:::remain-cpu event */

sched:::remain-cpu
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched remain-cpu\n", execname, pid, tid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
