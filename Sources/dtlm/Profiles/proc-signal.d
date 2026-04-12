/* Print every proc::: signal-related event */

proc:::signal-send,
proc:::signal-clear,
proc:::signal-discard
/* @dtlm-predicate */
{
    printf("%s[%d]: proc %s\n", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
