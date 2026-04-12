/*
 * Trace PostgreSQL queries via USDT probes.
 * Requires PostgreSQL built with --enable-dtrace.
 * Usage: dtlm watch postgresql-queries --param pid=<postgres-pid>
 */

pid${pid}::query__start:entry
{
    printf("postgres[%d]: query-start %s\n", pid, copyinstr(arg0));
}

pid${pid}::query__done:entry
{
    printf("postgres[%d]: query-done\n", pid);
}

pid${pid}::transaction__start:entry
{
    printf("postgres[%d]: transaction-start\n", pid);
}

pid${pid}::transaction__commit:entry
{
    printf("postgres[%d]: transaction-commit\n", pid);
}

pid${pid}::transaction__abort:entry
{
    printf("postgres[%d]: transaction-abort\n", pid);
}
