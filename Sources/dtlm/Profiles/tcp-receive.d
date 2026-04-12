/* Print every tcp:::receive event */

tcp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp recv len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
