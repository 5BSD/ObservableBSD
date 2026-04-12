/*
 * Quantize kernel adaptive-mutex wait time by execname.
 * Equivalent of Apple Instruments' Mutex Contention.
 */

lockstat:::adaptive-block
/* @dtlm-predicate */
{
    @block[execname] = quantize(arg1);
}

lockstat:::adaptive-spin
/* @dtlm-predicate */
{
    @spin[execname] = quantize(arg1);
}

dtrace:::END
{
    printf("\n--- adaptive mutex block (ns) ---\n");
    printa(@block);
    printf("\n--- adaptive mutex spin (ns) ---\n");
    printa(@spin);
}
