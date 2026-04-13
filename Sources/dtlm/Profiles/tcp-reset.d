/*
 * TCP reset/refused/abort audit.
 *
 * Traces TCP connection resets and aborts separately from
 * retransmits. High reset rates indicate misconfigured
 * services, firewall interference, or application bugs.
 */

fbt::tcp_respond:entry
/* @dtlm-predicate */
{
    @resets[execname] = count();
    printf("%s[%d]: tcp_respond (RST)\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::tcp_drop:entry
/* @dtlm-predicate */
{
    @drops[execname] = count();
    printf("%s[%d]: tcp_drop\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

dtrace:::END
{
    printf("\n--- TCP resets sent by process ---\n");
    printa("%-30s %@d\n", @resets);
    printf("\n--- TCP drops by process ---\n");
    printa("%-30s %@d\n", @drops);
}
