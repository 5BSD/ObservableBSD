/*
 * kqueue audit — kqueue creation and kevent registration.
 *
 * Traces kqueue(2) and kevent(2) calls to show event-queue
 * usage patterns. Useful for understanding how applications
 * use FreeBSD's event notification mechanism.
 */

syscall::kqueue:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kqueue\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::kevent:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: kevent fd=%d nchanges=%d nevents=%d\n",
        execname, pid, arg0, arg1, arg3);
    @kevent_calls[execname] = count();
}

dtrace:::END
{
    printf("\n--- kevent call count by process ---\n");
    printa("%-30s %@d\n", @kevent_calls);
}
