/*
 * Credential change audit — setuid/setgid/setgroups/setlogin.
 *
 * Traces privilege escalation and de-escalation events.
 * Essential for security auditing and forensics on
 * multi-user systems.
 */

syscall::setuid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setuid(%d)\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::seteuid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: seteuid(%d)\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setgid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setgid(%d)\n", execname, pid, arg0);
}

syscall::setegid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setegid(%d)\n", execname, pid, arg0);
}

syscall::setgroups:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setgroups ngroups=%d\n", execname, pid, arg0);
}

syscall::setlogin:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setlogin(\"%s\")\n", execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setresuid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setresuid(%d, %d, %d)\n",
        execname, pid, arg0, arg1, arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::setresgid:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: setresgid(%d, %d, %d)\n",
        execname, pid, arg0, arg1, arg2);
}
