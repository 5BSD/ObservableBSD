/* Print every block-I/O done event */

io:::done
/* @dtlm-predicate */
{
    printf("%s[%d]: io done\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
