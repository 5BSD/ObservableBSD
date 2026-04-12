/* Print every proc:::exec-success and proc:::exec-failure event */

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-success\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-failure (errno=%d)\n", execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
