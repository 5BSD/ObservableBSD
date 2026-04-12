/* Print every block-I/O start event */

io:::start
/* @dtlm-predicate */
{
    printf("%s[%d]: io start", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
