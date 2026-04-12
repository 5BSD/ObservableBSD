/* Print every tcp:::connect-established */

tcp:::connect-established
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp connect-established", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
