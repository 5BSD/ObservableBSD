/*
 * Exec audit — rich process start/exit with context.
 *
 * Traces proc:::exec-success and proc:::exit with parent PID,
 * UID, GID, and jail ID context. More detailed than exec-tree
 * for security auditing and compliance logging.
 */

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: exec ppid=%d uid=%d gid=%d jid=%d\n",
        execname, pid, ppid, uid, gid,
        curproc->p_ucred->cr_prison->pr_id);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-failure ppid=%d uid=%d\n",
        execname, pid, ppid, uid);
    @exec_failures[execname] = count();
}

proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: exit uid=%d\n", execname, pid, uid);
}

dtrace:::END
{
    printf("\n--- Exec failures by process ---\n");
    printa("%-30s %@d\n", @exec_failures);
}
