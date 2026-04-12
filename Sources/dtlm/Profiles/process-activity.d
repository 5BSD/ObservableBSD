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
    printf("%s[%d]: create", execname, pid);
    /* @dtlm-ustack */
}

proc:::exec-success
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-success", execname, pid);
    /* @dtlm-ustack */
}

proc:::exec-failure
/* @dtlm-predicate */
{
    printf("%s[%d]: exec-failure", execname, pid);
}

proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: exit", execname, pid);
    /* @dtlm-ustack */
}

proc:::signal-send
/* @dtlm-predicate */
{
    printf("%s[%d]: signal-send", execname, pid);
}
