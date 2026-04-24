/* Print every udplite:::send event (requires kernel UDP-Lite support) */

udplite:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
