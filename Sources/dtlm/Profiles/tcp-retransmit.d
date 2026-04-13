/*
 * TCP retransmit and reset events.
 *
 * Traces TCP retransmissions and connection resets for network
 * diagnosis. High retransmit rates indicate congestion, packet
 * loss, or misconfigured timeouts.
 */

tcp:::retransmit
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp retransmit %s:%d -> %s:%d\n",
        execname, pid,
        args[2]->ip_saddr, args[4]->tcp_sport,
        args[2]->ip_daddr, args[4]->tcp_dport);
    @retransmits[execname, args[2]->ip_daddr] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::tcp_timer_rexmt:entry
/* @dtlm-predicate */
{
    @rexmt_timeouts[execname] = count();
}

dtrace:::END
{
    printf("\n--- Retransmits by process/destination ---\n");
    printa("%-20s %-20s %@d\n", @retransmits);
    printf("\n--- Retransmit timeouts by process ---\n");
    printa("%-20s %@d\n", @rexmt_timeouts);
}
