/* Print every proc:::create event */

proc:::create
/* @dtlm-predicate */
{
    printf("%s[%d]: proc create\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
