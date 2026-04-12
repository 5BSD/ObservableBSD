/*
 * Lock Contention — Apple Instruments Spin/Mutex Contention equivalent.
 *
 * Aggregates the time spent blocked or spinning on every lock kind:
 * adaptive mutex, spin, rwlock (reader and writer). Quantized in ns
 * by execname so you can see who's blocking and how long.
 */

lockstat:::adaptive-block
/* @dtlm-predicate */
{
    @adaptive_block[execname] = quantize(arg1);
}

lockstat:::adaptive-spin
/* @dtlm-predicate */
{
    @adaptive_spin[execname] = quantize(arg1);
}

lockstat:::spin-spin
/* @dtlm-predicate */
{
    @spin_spin[execname] = quantize(arg1);
}

lockstat:::rw-block
/* @dtlm-predicate */
{
    @rw_block[execname] = quantize(arg1);
}

dtrace:::END
{
    printf("\n=== adaptive mutex block (ns) ===\n");
    printa(@adaptive_block);
    printf("\n=== adaptive mutex spin (ns) ===\n");
    printa(@adaptive_spin);
    printf("\n=== spin lock spin (ns) ===\n");
    printa(@spin_spin);
    printf("\n=== rwlock block (ns) ===\n");
    printa(@rw_block);
}
