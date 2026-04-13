/*
 * Virtual memory activity: faults, page alloc/free counts.
 * Traces vm_fault events per-process and aggregates page
 * allocations and frees by execname.
 */

fbt::vm_fault:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vm_fault type=%d addr=0x%p\n",
        execname, pid, arg2, arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::vm_page_alloc:entry
/* @dtlm-predicate */
{
    @pgalloc[execname] = count();
}

fbt::vm_page_free:entry
/* @dtlm-predicate */
{
    @pgfree[execname] = count();
}

dtrace:::END
{
    printf("\n--- Page allocations by process ---\n");
    printa("%-30s %@d\n", @pgalloc);
    printf("\n--- Page frees by process ---\n");
    printa("%-30s %@d\n", @pgfree);
}
