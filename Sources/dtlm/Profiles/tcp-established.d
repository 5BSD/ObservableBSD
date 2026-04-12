/* Print tcp accept-established and connect-established events */

tcp:::accept-established,
tcp:::connect-established
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp %s", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
