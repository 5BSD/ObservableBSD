/* Print every openat(2) call with the path argument */

syscall::openat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: openat(_, \"%s\")",
           execname, pid, copyinstr(arg1));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
