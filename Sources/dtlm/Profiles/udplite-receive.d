/* Print every udplite:::receive event */

udplite:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udplite recv\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
