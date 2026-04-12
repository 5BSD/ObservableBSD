/* Print every proc:::exec-success event */

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: proc exec-success\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
