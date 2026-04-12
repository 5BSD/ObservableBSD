/* Print every tcp:::connect-refused */

tcp:::connect-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp connect-refused\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
