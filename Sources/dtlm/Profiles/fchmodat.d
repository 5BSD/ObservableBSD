/* Print every fchmodat(2) call with path and mode */

syscall::fchmodat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: fchmodat(_, \"%s\", 0%o)",
           execname, pid, copyinstr(arg1), (mode_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
