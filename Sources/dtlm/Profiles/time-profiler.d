/* Time Profiler — sample at 997 Hz, aggregate by user stack */

profile-997
/* @dtlm-predicate */
{
    @samples[ustack()] = count();
}

dtrace:::END
{
    printa(@samples);
}
