/* Print every tcp send and receive event with byte count */

tcp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp send len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

tcp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp recv len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
