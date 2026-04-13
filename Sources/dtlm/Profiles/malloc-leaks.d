/*
 * Track outstanding allocations to detect leaks in a process.
 * Tracks malloc/free pairs by pointer address. At exit, reports
 * allocation sites (by stack) that were never freed.
 * Usage: dtlm watch malloc-leaks --param pid=<pid> --duration 10
 */

pid${pid}::malloc:entry
{
    self->msize = arg0;
}

pid${pid}::malloc:return
/arg1 != 0/
{
    /* Record the allocation: pointer → size and stack. */
    alloc_size[arg1] = self->msize;
    alloc_stack[arg1] = ustack();
    @outstanding_bytes[ustack()] = sum(self->msize);
    @outstanding_count[ustack()] = count();
    self->msize = 0;
}

pid${pid}::free:entry
/arg0 != 0 && alloc_size[arg0]/
{
    /* Matched free — subtract from outstanding. */
    @outstanding_bytes[alloc_stack[arg0]] = sum(-alloc_size[arg0]);
    @outstanding_count[alloc_stack[arg0]] = sum(-1);
    alloc_size[arg0] = 0;
    alloc_stack[arg0] = 0;
}

dtrace:::END
{
    printf("\n--- Outstanding allocations by site (potential leaks) ---\n");
    printf("  COUNT   BYTES  STACK\n");
    printa(@outstanding_count);
    printa(@outstanding_bytes);
}
