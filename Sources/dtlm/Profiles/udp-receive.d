/* Print every udp:::receive event */

udp:::receive
/* @dtlm-predicate */
{
    printf("%s[%d]: udp recv len=%d\n", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
