/*
 * Trace SCTP send events.
 */

sctp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: sctp send %d bytes\n",
        execname, pid, args[2]->sctps_length);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
