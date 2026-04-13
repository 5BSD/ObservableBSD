/*
 * Block I/O latency — service time histograms by device and process.
 *
 * Measures the time between io:::start and io:::done for each
 * block I/O request. Aggregates as histograms to show the latency
 * distribution of disk operations.
 */

io:::start
/* @dtlm-predicate */
{
    start_ts[arg0] = timestamp;
    start_exec[arg0] = execname;
    start_pid[arg0] = pid;
}

io:::done
/start_ts[arg0]/
{
    this->elapsed_us = (timestamp - start_ts[arg0]) / 1000;
    this->bytes = args[0]->b_bcount;
    @latency[start_exec[arg0], args[1]->dev_statname] = quantize(this->elapsed_us);
    @bytes[start_exec[arg0], args[1]->dev_statname] = quantize(this->bytes);
    @iops[start_exec[arg0], args[1]->dev_statname] = count();
    start_ts[arg0] = 0;
    start_exec[arg0] = 0;
    start_pid[arg0] = 0;
}

dtrace:::END
{
    printf("\n--- I/O latency (us) by process/device ---\n");
    printa(@latency);
    printf("\n--- I/O size (bytes) by process/device ---\n");
    printa(@bytes);
    printf("\n--- IOPS by process/device ---\n");
    printa("%-20s %-12s %@d\n", @iops);
}
