/* Print every UDP-Lite send and receive event */

udplite:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

udplite:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite recv\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
