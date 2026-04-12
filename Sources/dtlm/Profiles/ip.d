/* Print every IP send and receive event */

ip:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: ip send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

ip:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: ip recv\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
