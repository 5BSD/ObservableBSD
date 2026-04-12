/* Print every sendmsg(2) entry */

syscall::sendmsg:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: sendmsg(fd=%d)\n",
           execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
