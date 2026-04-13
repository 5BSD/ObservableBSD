/*
 * Trace Node.js garbage collection via USDT probes.
 * Usage: dtlm watch node-gc --param pid=<node-pid>
 */

pid${pid}::gc__start:entry
{
    self->gcstart = timestamp;
    printf("node[%d]: GC start type=%d\n", pid, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

pid${pid}::gc__done:entry
/self->gcstart/
{
    this->elapsed_us = (timestamp - self->gcstart) / 1000;
    printf("node[%d]: GC done %dus type=%d\n", pid, this->elapsed_us, arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
    @gc_latency["gc-us"] = quantize(this->elapsed_us);
    self->gcstart = 0;
}

dtrace:::END
{
    printa(@gc_latency);
}
