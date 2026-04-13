/*
 * ZFS I/O latency — service time histograms by operation type.
 *
 * Traces ZFS I/O pipeline start/done events and aggregates
 * latency by operation type (read, write, free, claim, ioctl).
 * Requires the zfs.ko kernel module.
 */

fbt:zfs:zio_execute:entry
/* @dtlm-predicate */
{
    self->zio_ts = timestamp;
    self->zio_type = args[0]->io_type;
}

fbt:zfs:zio_done:entry
/self->zio_ts/
{
    this->elapsed_us = (timestamp - self->zio_ts) / 1000;
    @latency[self->zio_type == 1 ? "read" :
             self->zio_type == 2 ? "write" :
             self->zio_type == 3 ? "free" :
             self->zio_type == 4 ? "claim" :
             "other"] = quantize(this->elapsed_us);
    @iops[self->zio_type == 1 ? "read" :
          self->zio_type == 2 ? "write" :
          self->zio_type == 3 ? "free" :
          self->zio_type == 4 ? "claim" :
          "other"] = count();
    self->zio_ts = 0;
    self->zio_type = 0;
}

dtrace:::END
{
    printf("\n--- ZFS I/O latency (us) by type ---\n");
    printa(@latency);
    printf("\n--- ZFS IOPS by type ---\n");
    printa("%-10s %@d\n", @iops);
}
