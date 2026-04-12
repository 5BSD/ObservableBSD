/* Print every tcp:::accept-established */

tcp:::accept-established
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp accept-established\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
