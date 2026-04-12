/* Print every tcp accept event (established + refused) */

tcp:::accept-established,
tcp:::accept-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp %s", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
