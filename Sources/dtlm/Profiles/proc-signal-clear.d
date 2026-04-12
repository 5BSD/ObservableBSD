/* Print every proc:::signal-clear event */

proc:::signal-clear
/* @dtlm-predicate */
{
    printf("%s[%d]: proc signal-clear\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
