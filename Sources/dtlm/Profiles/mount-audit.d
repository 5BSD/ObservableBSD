/*
 * Mount audit — mount, unmount, chroot activity.
 *
 * Traces filesystem mount/unmount and chroot calls.
 * Important system-level activity stream for host
 * forensics and configuration drift detection.
 */

syscall::nmount:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: nmount\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::unmount:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: unmount(\"%s\")\n", execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::chroot:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: chroot(\"%s\")\n", execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
