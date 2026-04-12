/*
 * Trace SCTP receive events.
 */

sctp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: sctp receive %d bytes\n",
        execname, pid, args[2]->sctps_length);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
