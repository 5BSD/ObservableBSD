/*
 * Process descriptor audit — pdfork, pdgetpid, pdkill, pdwait4.
 *
 * Capsicum's process descriptor facility. Complements
 * capsicum-audit for capability-oriented process management.
 * FreeBSD-specific.
 */

syscall::pdfork:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pdfork\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::pdgetpid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pdgetpid fd=%d\n", execname, pid, arg0);
}

syscall::pdkill:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pdkill fd=%d sig=%d\n", execname, pid, arg0, arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::pdwait4:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pdwait4 fd=%d\n", execname, pid, arg0);
}
