/*
 * Off-CPU profiler — blocked/waiting stack analysis.
 *
 * Records the kernel stack at every sched:::off-cpu event and
 * aggregates by stack and elapsed blocked time. At exit, prints
 * the stacks where threads spent the most time waiting. Pair
 * with time-profiler for a complete on-CPU + off-CPU picture.
 */

sched:::off-cpu
/* @dtlm-predicate */
{
    self->offcpu_ts = timestamp;
}

sched:::on-cpu
/self->offcpu_ts/
{
    this->blocked_us = (timestamp - self->offcpu_ts) / 1000;
    @blocked_time[execname, stack()] = sum(this->blocked_us);
    @blocked_count[execname] = count();
    self->offcpu_ts = 0;
}

dtrace:::END
{
    printf("\n--- Off-CPU time by stack (microseconds) ---\n");
    printa(@blocked_time);
    printf("\n--- Off-CPU event count by process ---\n");
    printa("%-30s %@d\n", @blocked_count);
}
