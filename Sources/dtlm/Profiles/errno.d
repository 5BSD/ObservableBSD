/* Print every syscall return that delivered a non-zero errno */

syscall:::return
/errno != 0 /* @dtlm-predicate-and */ /
{
    printf("%s[%d]: %s -> errno %d\n", execname, pid, probefunc, errno);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
