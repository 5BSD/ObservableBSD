/*
 * CAP_RT capability framework — connect, send, receive, call events.
 *
 * Traces the cap_rt message-passing capability framework. Shows
 * service connects, async message flow, and sync calls.
 * Requires cap_rt.ko loaded.
 */

cap_rt:::connect
/* @dtlm-predicate */
{
    printf("%s[%d]: cap_rt connect service=%s badge=%d\n",
        execname, pid, copyinstr(arg0), arg1);
    @connects[execname, copyinstr(arg0)] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

cap_rt:::send
/* @dtlm-predicate */
{
    @sends[execname, copyinstr(arg0)] = count();
}

cap_rt:::recv
/* @dtlm-predicate */
{
    @recvs[execname, copyinstr(arg0)] = count();
}

cap_rt:::call
/* @dtlm-predicate */
{
    @calls[execname, copyinstr(arg0)] = count();
}

cap_rt:::revoke
/* @dtlm-predicate */
{
    printf("%s[%d]: cap_rt revoke service=%s badge=%d reason=%d\n",
        execname, pid, copyinstr(arg0), arg1, arg2);
    @revokes[execname, copyinstr(arg0)] = count();
}

cap_rt:::close
/* @dtlm-predicate */
{
    @closes[execname, copyinstr(arg0)] = count();
}

dtrace:::END
{
    printf("\n--- cap_rt connects ---\n");
    printf("%-20s %-20s %8s\n", "EXECNAME", "SERVICE", "COUNT");
    printa("%-20s %-20s %@8d\n", @connects);
    printf("\n--- cap_rt sends ---\n");
    printa("%-20s %-20s %@8d\n", @sends);
    printf("\n--- cap_rt recvs ---\n");
    printa("%-20s %-20s %@8d\n", @recvs);
    printf("\n--- cap_rt calls ---\n");
    printa("%-20s %-20s %@8d\n", @calls);
    printf("\n--- cap_rt revokes ---\n");
    printa("%-20s %-20s %@8d\n", @revokes);
    printf("\n--- cap_rt closes ---\n");
    printa("%-20s %-20s %@8d\n", @closes);
}
