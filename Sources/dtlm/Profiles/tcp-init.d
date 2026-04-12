/* Print every tcp connection initialization event (accept + connect lifecycle) */

tcp:::accept-established,
tcp:::accept-refused,
tcp:::connect-established,
tcp:::connect-refused,
tcp:::connect-request
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp %s", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
