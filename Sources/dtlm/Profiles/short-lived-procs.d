/*
 * Short-lived processes — processes that spawn and exit quickly.
 *
 * Tracks process creation to exit time. Short-lived processes
 * (< 100ms) are often shell script churn, cron jobs, or health
 * checks. High rates waste fork/exec overhead.
 */

proc:::create
/* @dtlm-predicate */
{
    proc_start[args[0]->p_pid] = timestamp;
}

proc:::exit
/proc_start[pid]/
{
    this->lifetime_us = (timestamp - proc_start[pid]) / 1000;
    printf("%s[%d]: exit after %dus\n", execname, pid, this->lifetime_us);
    @lifetime[execname] = quantize(this->lifetime_us);
    @short_count[execname] = count();
    proc_start[pid] = 0;
}

dtrace:::END
{
    printf("\n--- Process lifetime (us) by execname ---\n");
    printa(@lifetime);
    printf("\n--- Process exit count by execname ---\n");
    printa("%-30s %@d\n", @short_count);
}
