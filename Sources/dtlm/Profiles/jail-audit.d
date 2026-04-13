/*
 * Jail audit — jail creation, attachment, and process transitions.
 *
 * Traces jail(2), jail_attach(2), and jail_remove(2) calls.
 * Useful for multi-tenant hosts to monitor jail lifecycle
 * and process containment. FreeBSD-specific.
 */

syscall::jail:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: jail create\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::jail_attach:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: jail_attach jid=%d\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::jail_remove:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: jail_remove jid=%d\n", execname, pid, arg0);
}

syscall::jail_set:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: jail_set\n", execname, pid);
}

syscall::jail_get:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: jail_get\n", execname, pid);
}

dtrace:::END
{
}
