/* Print every SCTP association state change */

sctp:::state-change
/* @dtlm-predicate */
{
    printf("%s[%d]: sctp state %d -> %d\n",
        execname, pid,
        args[5]->sctps_state, args[3]->sctps_state);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
