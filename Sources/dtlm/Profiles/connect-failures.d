/*
 * Connect failures — failed outbound connections by errno and process.
 *
 * Aggregates connect(2) failures to identify connection refused,
 * timeouts, unreachable hosts, and other network issues.
 */

syscall::connect:return
/arg0 == -1 /* @dtlm-predicate-and *//
{
    printf("%s[%d]: connect failed errno=%d\n", execname, pid, errno);
    @failures[execname, errno] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

dtrace:::END
{
    printf("\n--- Connect failures by process/errno ---\n");
    printf("%-20s %6s %8s\n", "EXECNAME", "ERRNO", "COUNT");
    printa("%-20s %6d %@8d\n", @failures);
}
