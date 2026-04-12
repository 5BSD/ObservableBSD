/* Print every open(2) and openat(2) call with the path argument */

syscall::open:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: open(\"%s\")\n",
           execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::openat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: openat(_, \"%s\")\n",
           execname, pid, copyinstr(arg1));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
