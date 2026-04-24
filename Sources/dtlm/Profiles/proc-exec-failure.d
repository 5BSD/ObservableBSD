/* Print every proc:::exec-failure event with errno */

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: proc exec-failure errno=%d\n", execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
