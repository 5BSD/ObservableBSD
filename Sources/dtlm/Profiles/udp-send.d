/* Print every udp:::send event */

udp:::send
/* @dtlm-predicate */
{
    printf("%s[%d]: udp send len=%d", execname, pid, args[2]->ip_plength);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
