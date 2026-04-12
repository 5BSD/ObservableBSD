/*
 * Trace Node.js HTTP server requests via USDT probes.
 * Requires Node.js built with --with-dtrace.
 * Usage: dtlm watch node-http --param pid=<node-pid>
 */

pid${pid}::http__server__request:entry
{
    printf("node[%d]: HTTP %s %s\n",
        pid, copyinstr(arg4), copyinstr(arg5));
}

pid${pid}::http__server__response:entry
{
    printf("node[%d]: HTTP response\n", pid);
}

pid${pid}::http__client__request:entry
{
    printf("node[%d]: HTTP client %s %s\n",
        pid, copyinstr(arg4), copyinstr(arg5));
}

pid${pid}::http__client__response:entry
{
    printf("node[%d]: HTTP client response\n", pid);
}
