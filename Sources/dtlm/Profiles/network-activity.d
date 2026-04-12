/*
 * Network Activity — Apple Instruments equivalent.
 *
 * Combines tcp:::send / tcp:::receive / tcp:::state-change /
 * udp:::send / udp:::receive into one event stream so you can
 * watch the entire network stack at once. Add --with-ustack to
 * see who's making the calls.
 */

tcp:::state-change
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp state %d -> %d",
           execname, pid, args[5]->tcps_state, args[3]->tcps_state);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

tcp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp send len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

tcp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp recv len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

udp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udp send len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

udp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udp recv len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
