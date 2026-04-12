/* Print every tcp:::connect-established */

tcp:::connect-established
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp connect-established\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
