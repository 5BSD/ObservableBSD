/*
 * ZFS ARC activity — cache hits, misses, and evictions.
 *
 * Traces the ZFS Adaptive Replacement Cache to show cache
 * effectiveness. High miss rates indicate the ARC is undersized
 * for the workload.
 */

fbt:zfs:arc_read:entry
/* @dtlm-predicate */
{
    @arc_reads[execname] = count();
}

fbt:zfs:arc_read_done:entry
/* @dtlm-predicate */
{
    @arc_hits[execname] = count();
}

fbt:zfs:arc_evict:entry
/* @dtlm-predicate */
{
    @arc_evictions = count();
}

dtrace:::END
{
    printf("\n--- ARC reads by process ---\n");
    printa("%-30s %@d\n", @arc_reads);
    printf("\n--- ARC hits by process ---\n");
    printa("%-30s %@d\n", @arc_hits);
    printf("\n--- ARC evictions ---\n");
    printa("%@d\n", @arc_evictions);
}
