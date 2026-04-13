/*
 * Kernel module audit — kldload, kldunload, modfind.
 *
 * Traces kernel module lifecycle events. Useful for host
 * forensics and drift detection — shows who loaded or
 * unloaded kernel modules and when. FreeBSD-specific.
 */

syscall::kldload:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kldload(\"%s\")\n", execname, pid, copyinstr(arg0));
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::kldunload:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kldunload fileid=%d\n", execname, pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::kldfirstmod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kldfirstmod fileid=%d\n", execname, pid, arg0);
}

syscall::modfind:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: modfind(\"%s\")\n", execname, pid, copyinstr(arg0));
}

syscall::kldstat:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kldstat fileid=%d\n", execname, pid, arg0);
}
