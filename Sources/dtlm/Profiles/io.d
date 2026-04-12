/* Print every block-I/O start and done event */

io:::start
/* @dtlm-predicate */
{
    printf("%s[%d]: io start", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

io:::done
/* @dtlm-predicate */
{
    printf("%s[%d]: io done", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
