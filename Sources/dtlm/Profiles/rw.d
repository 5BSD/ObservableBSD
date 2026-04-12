/* Print every read(2)/write(2)/pread(2)/pwrite(2) entry with fd and length */

syscall::read:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: read(fd=%d, %d)", execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::write:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: write(fd=%d, %d)", execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::pread:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pread(fd=%d, %d)", execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::pwrite:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: pwrite(fd=%d, %d)", execname, pid, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
