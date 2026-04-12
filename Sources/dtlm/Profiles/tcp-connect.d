/* Print every tcp connect lifecycle event (request + established + refused) */

tcp:::connect-request,
tcp:::connect-established,
tcp:::connect-refused
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp %s", execname, pid, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
