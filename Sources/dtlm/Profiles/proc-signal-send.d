/* Print every proc:::signal-send event */

proc:::signal-send
/* @dtlm-predicate */
{
    printf("%s[%d]: proc signal-send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
