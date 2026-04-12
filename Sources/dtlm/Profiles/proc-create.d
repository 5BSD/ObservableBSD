/* Print every proc:::create event */

proc:::create
/* @dtlm-predicate */
{
    printf("%s[%d]: proc create", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
