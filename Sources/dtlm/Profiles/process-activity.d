/*
 * Process Activity — Apple Instruments Activity Monitor equivalent.
 *
 * Tracks the process lifecycle: creation, exec, exit, signal delivery.
 * Useful for "what is starting and stopping on this host" forensic
 * logging.
 */

proc:::create
/* @dtlm-predicate */
{
    printf("%s[%d]: create\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-success\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-failure\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: exit\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

proc:::signal-send
/* @dtlm-predicate */
{
    printf("%s[%d]: signal-send sig=%d to pid=%d\n", execname, pid, (int)arg2, (int)arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
