/* Print every tcp:::connect-request */

tcp:::connect-request
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp connect-request", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
