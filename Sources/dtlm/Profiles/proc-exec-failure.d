/* Print every proc:::exec-failure event */

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: proc exec-failure\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
