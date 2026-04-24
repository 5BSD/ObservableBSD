/* Print sched execution transitions (sleep + wakeup) — dwatch parity */

sched:::sleep,
sched:::wakeup
/* @dtlm-predicate */
{
    printf("%s[%d/tid %d]: sched %s\n", execname, pid, tid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
