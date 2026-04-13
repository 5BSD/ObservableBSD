/*
 * Discover pid-provider probes by firing them at runtime.
 *
 * Attaches to every entry probe in a process and prints the
 * full probe name on each firing. This is a runtime discovery
 * tool, not a static inventory — only probes that fire during
 * the duration window will appear.
 *
 * For a static probe listing, use `dtlm probes --pid <pid>`.
 *
 * Usage: dtlm watch usdt-list --param pid=<pid> --duration 1
 */

pid${pid}:::entry
{
    printf("%s[%d]: %s:%s:%s:%s\n",
        execname, pid, probeprov, probemod, probefunc, probename);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
