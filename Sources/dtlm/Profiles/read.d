/* Print every read(2) entry with fd and length */

syscall::read:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: read(fd=%d, %d)",
           execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
