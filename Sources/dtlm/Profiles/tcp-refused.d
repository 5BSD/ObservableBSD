/* Print tcp accept-refused and connect-refused events */

tcp:::accept-refused,
tcp:::connect-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp %s", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
