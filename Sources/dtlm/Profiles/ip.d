/* Print every IP send and receive event */

ip:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: ip send", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

ip:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: ip recv", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
