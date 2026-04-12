/* Print every udplite:::send event */

udplite:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite send", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
