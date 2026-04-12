/* Print every ip:::send event */

ip:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: ip send", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
