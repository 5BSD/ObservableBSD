/* Print every ip:::receive event */

ip:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: ip recv\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
