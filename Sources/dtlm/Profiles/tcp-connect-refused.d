/* Print every tcp:::connect-refused */

tcp:::connect-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp connect-refused", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
