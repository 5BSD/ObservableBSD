/*
 * GEOM disk I/O requests — block layer below VFS.
 *
 * Traces g_io_request entries to show disk-level I/O activity.
 * GEOM sits between VFS and physical devices. Aggregates I/O
 * counts by process. Complement with io-latency for timing.
 */

fbt::g_io_request:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: g_io_request\n", execname, pid);
    @geom_io[execname] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

dtrace:::END
{
    printf("\n--- GEOM I/O requests by process ---\n");
    printa("%-30s %@d\n", @geom_io);
}
