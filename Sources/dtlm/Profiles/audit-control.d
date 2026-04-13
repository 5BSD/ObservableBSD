/*
 * OpenBSM audit control — auditon, auditctl, setaudit, setauid.
 *
 * Traces the audit subsystem control plane. Shows who is
 * modifying audit policy, rotating audit trails, or changing
 * audit session state. Essential for host security forensics.
 * FreeBSD-specific (OpenBSM).
 */

syscall::auditon:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: auditon cmd=%d\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::auditctl:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: auditctl(\"%s\")\n", execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setaudit:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setaudit\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setaudit_addr:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setaudit_addr\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setauid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setauid\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::getaudit:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: getaudit\n", execname, pid);
}

syscall::getaudit_addr:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: getaudit_addr\n", execname, pid);
}

syscall::getauid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: getauid\n", execname, pid);
}
