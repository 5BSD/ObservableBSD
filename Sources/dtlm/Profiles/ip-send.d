/* Print every ip:::send event */

ip:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: ip send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
