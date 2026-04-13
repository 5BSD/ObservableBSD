/*
 * Thread lifetime — create to exit duration by process.
 *
 * Tracks how long threads live. Short-lived threads indicate
 * thread-per-request patterns or thread pool churn.
 */

proc:::lwp-create
/* @dtlm-predicate */
{
    thread_start[tid] = timestamp;
    printf("%s[%d/tid %d]: thread create\n", execname, pid, tid);
}

proc:::lwp-exit
/thread_start[tid]/
{
    this->lifetime_us = (timestamp - thread_start[tid]) / 1000;
    printf("%s[%d/tid %d]: thread exit %dus\n",
        execname, pid, tid, this->lifetime_us);
    @lifetime[execname] = quantize(this->lifetime_us);
    thread_start[tid] = 0;
}

dtrace:::END
{
    printf("\n--- Thread lifetime (us) by process ---\n");
    printa(@lifetime);
}
