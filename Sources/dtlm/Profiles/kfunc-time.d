/*
 * Measure time spent in a kernel function.
 * Usage: dtlm watch kfunc-time --param func=<kernel-function>
 */

fbt::${func}:entry
/* @dtlm-predicate */
{
    self->entry = timestamp;
}

fbt::${func}:return
/self->entry /* @dtlm-predicate-and *//
{
    this->elapsed_us = (timestamp - self->entry) / 1000;
    printf("%s[%d]: ${func} %dus\n", execname, pid, this->elapsed_us);
    @latency["${func}-us"] = quantize(this->elapsed_us);
    self->entry = 0;
}

dtrace:::END
{
    printa(@latency);
}
