/* Print every lchmod(2) call with path and mode */

syscall::lchmod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: lchmod(\"%s\", 0%o)\n",
           execname, pid, copyinstr(arg0), (mode_t)arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
