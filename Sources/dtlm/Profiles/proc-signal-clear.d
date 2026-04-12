/* Print every proc:::signal-clear event */

proc:::signal-clear
/* @dtlm-predicate */
{
    printf("%s[%d]: proc signal-clear", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
