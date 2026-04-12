/* Print every proc:::signal-discard event */

proc:::signal-discard
/* @dtlm-predicate */
{
    printf("%s[%d]: proc signal-discard", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
