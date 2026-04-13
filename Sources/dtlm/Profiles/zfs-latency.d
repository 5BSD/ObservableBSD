/*
 * ZFS I/O latency — service time histograms.
 *
 * Measures the time between zio_execute entry and zio_done
 * entry in the ZFS I/O pipeline. Aggregates latency as a
 * histogram by process. Requires zfs.ko loaded.
 */

fbt:zfs:zio_execute:entry
/* @dtlm-predicate */
{
    self->zio_ts = timestamp;
}

fbt:zfs:zio_done:entry
/self->zio_ts/
{
    this->elapsed_us = (timestamp - self->zio_ts) / 1000;
    @latency[execname] = quantize(this->elapsed_us);
    @iops[execname] = count();
    self->zio_ts = 0;
}

dtrace:::END
{
    printf("\n--- ZFS I/O latency (us) by process ---\n");
    printa(@latency);
    printf("\n--- ZFS IOPS by process ---\n");
    printa("%-30s %@d\n", @iops);
}
