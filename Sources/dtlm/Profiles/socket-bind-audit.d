/*
 * Socket bind/listen/connect/accept audit with port context.
 *
 * Traces the full socket lifecycle: bind, listen, connect, and
 * accept calls with file descriptor context. Essential audit
 * profile for network-facing services.
 */

syscall::bind:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: bind fd=%d\n", execname, pid, arg0);
    @binds[execname] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::listen:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: listen fd=%d backlog=%d\n", execname, pid, arg0, arg1);
    @listens[execname] = count();
}

syscall::connect:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: connect fd=%d\n", execname, pid, arg0);
    @connects[execname] = count();
}

syscall::accept:entry,
syscall::accept4:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: %s fd=%d\n", execname, pid, probefunc, arg0);
    @accepts[execname] = count();
}

dtrace:::END
{
    printf("\n--- bind count by process ---\n");
    printa("%-30s %@d\n", @binds);
    printf("\n--- listen count by process ---\n");
    printa("%-30s %@d\n", @listens);
    printf("\n--- connect count by process ---\n");
    printa("%-30s %@d\n", @connects);
    printf("\n--- accept count by process ---\n");
    printa("%-30s %@d\n", @accepts);
}
