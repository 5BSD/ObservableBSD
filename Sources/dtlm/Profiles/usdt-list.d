/*
 * Fire on every USDT probe in a process to discover available probes.
 * Usage: dtlm watch usdt-list --param pid=<pid> --duration 1
 */

pid${pid}:::entry
{
    printf("%s[%d]: %s:%s:%s:%s\n",
        execname, pid, probeprov, probemod, probefunc, probename);
}
