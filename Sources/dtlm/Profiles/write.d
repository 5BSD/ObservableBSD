/* Print every write(2) entry with fd and length */

syscall::write:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: write(fd=%d, %d)",
           execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
