/*
 * Context switch frequency — aggregate sched transitions by process.
 *
 * High voluntary context switches (off-cpu) indicate I/O-bound
 * workloads. High involuntary switches (preempt) indicate CPU
 * contention.
 */

sched:::off-cpu
/* @dtlm-predicate */
{
    @voluntary[execname] = count();
}

sched:::preempt
/* @dtlm-predicate */
{
    @involuntary[execname] = count();
}

dtrace:::END
{
    printf("\n--- Voluntary context switches (off-cpu) by process ---\n");
    printa("%-30s %@d\n", @voluntary);
    printf("\n--- Involuntary context switches (preempt) by process ---\n");
    printa("%-30s %@d\n", @involuntary);
}
