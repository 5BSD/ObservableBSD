/* Print every tcp:::accept-refused */

tcp:::accept-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp accept-refused\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
