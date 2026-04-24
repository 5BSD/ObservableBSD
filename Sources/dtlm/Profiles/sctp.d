/* Print every SCTP send and receive event with payload length */

sctp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: sctp send %d bytes\n",
        execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

sctp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: sctp recv %d bytes\n",
        execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
