/*
 * File Activity — Apple Instruments equivalent.
 *
 * Combines the most useful filesystem syscalls into one stream:
 * open, close, read, write, stat, unlink, rename. Add --with-ustack
 * to see who's calling them.
 */

syscall::open:entry,
syscall::openat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: open(\"%s\")", execname, pid,
           probefunc == "open" ? copyinstr(arg0) : copyinstr(arg1));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::close:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: close(fd=%d)", execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::read:entry,
syscall::pread:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: %s(fd=%d, %d)", execname, pid, probefunc, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::write:entry,
syscall::pwrite:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: %s(fd=%d, %d)", execname, pid, probefunc, (int)arg0, (size_t)arg2);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::fstatat:entry
/* @dtlm-predicate */
{
    /* FreeBSD libc stat() is a wrapper around fstatat(AT_FDCWD, …) so
     * the path is in arg1 (the second argument to fstatat). */
    printf("%s[%d]: stat(\"%s\")", execname, pid, copyinstr(arg1));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::unlink:entry,
syscall::unlinkat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: %s(\"%s\")", execname, pid, probefunc,
           probefunc == "unlink" ? copyinstr(arg0) : copyinstr(arg1));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::rename:entry,
syscall::renameat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: rename", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
