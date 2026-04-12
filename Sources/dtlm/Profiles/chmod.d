/* Print every chmod / fchmod / lchmod / fchmodat call with path and mode */

syscall::chmod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: chmod(\"%s\", 0%o)",
           execname, pid, copyinstr(arg0), (mode_t)arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::lchmod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: lchmod(\"%s\", 0%o)",
           execname, pid, copyinstr(arg0), (mode_t)arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::fchmod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: fchmod(%d, 0%o)",
           execname, pid, (int)arg0, (mode_t)arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::fchmodat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: fchmodat(_, \"%s\", 0%o)",
           execname, pid, copyinstr(arg1), (mode_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
