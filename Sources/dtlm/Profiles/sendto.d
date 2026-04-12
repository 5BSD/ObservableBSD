/* Print every sendto(2) entry */

syscall::sendto:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: sendto(fd=%d, %d)",
           execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
