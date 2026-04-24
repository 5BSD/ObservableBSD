/* Print every TCP event — send, receive, and state change */

tcp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp send %d bytes\n", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

tcp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp recv %d bytes\n", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

tcp:::state-change
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp state %d -> %d\n", execname, pid, args[5]->tcps_state, args[3]->tcps_state);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
