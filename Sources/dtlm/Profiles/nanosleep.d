/* Print every syscall::nanosleep:entry */

syscall::nanosleep:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: nanosleep", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
