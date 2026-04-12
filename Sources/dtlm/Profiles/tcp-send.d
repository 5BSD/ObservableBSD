/* Print every tcp:::send event */

tcp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp send len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
