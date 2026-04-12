/*
 * Trace virtual memory page faults via the kernel vm_fault function.
 */

fbt::vm_fault:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vm_fault addr=0x%p\n", execname, pid, arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
