/* Print every tcp:::accept-established */

tcp:::accept-established
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp accept-established", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
