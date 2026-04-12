/* Print every recvmsg(2) entry */

syscall::recvmsg:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: recvmsg(fd=%d)",
           execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
