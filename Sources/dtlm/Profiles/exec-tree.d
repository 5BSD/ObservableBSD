/*
 * Process exec tree — parent/child lineage with command context.
 *
 * Traces process creation and exec events with parent PID and
 * the executed command path. Useful for forensic analysis of
 * what spawned what.
 */

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d] ppid=%d: exec-success %s\n",
        execname, pid, ppid, execname);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::create
/* @dtlm-predicate */
{
    printf("%s[%d]: fork -> child %d\n",
        execname, pid, args[0]->p_pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: exit\n", execname, pid);
}
