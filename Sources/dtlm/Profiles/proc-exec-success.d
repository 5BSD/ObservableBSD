/* Print every proc:::exec-success event */

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: proc exec-success", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
