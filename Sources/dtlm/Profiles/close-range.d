/*
 * Close-range audit — closefrom, close_range calls.
 *
 * Traces bulk descriptor close operations used for CLOEXEC
 * hygiene, post-fork cleanup, and security hardening.
 * FreeBSD-specific.
 */

syscall::closefrom:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: closefrom(fd=%d)\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::close_range:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: close_range(%d, %d, flags=0x%x)\n",
        execname, pid, arg0, arg1, arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
