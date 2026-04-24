/* Print every udplite:::receive event (requires kernel UDP-Lite support) */

udplite:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite recv\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
