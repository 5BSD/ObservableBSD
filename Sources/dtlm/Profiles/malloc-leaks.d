/*
 * Track outstanding allocations to detect leaks in a process.
 * Reports allocations that were never freed at exit.
 * Usage: dtlm watch malloc-leaks --param pid=<pid> --duration 10
 */

pid${pid}::malloc:return
/arg1 != 0/
{
    allocs[arg1] = ustack();
    sizes[arg1] = self->msize;
}

pid${pid}::malloc:entry
{
    self->msize = arg0;
}

pid${pid}::free:entry
/allocs[arg0] != 0/
{
    allocs[arg0] = 0;
    sizes[arg0] = 0;
}

dtrace:::END
{
    printf("\n--- Outstanding allocations (potential leaks) ---\n");
    printa(@outstanding);
}
