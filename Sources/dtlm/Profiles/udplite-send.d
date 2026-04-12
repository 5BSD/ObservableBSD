/* Print every udplite:::send event */

udplite:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite send\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
