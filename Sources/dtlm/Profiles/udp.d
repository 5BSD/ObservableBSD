/* Print every UDP send and receive with payload length */

udp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udp send len=%d\n", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

udp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udp recv len=%d\n", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
