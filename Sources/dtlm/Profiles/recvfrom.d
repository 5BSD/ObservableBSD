/* Print every recvfrom(2) entry */

syscall::recvfrom:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: recvfrom(fd=%d, %d)\n",
           execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
