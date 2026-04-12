/*
 * Trace a kernel function via FBT (function boundary tracing).
 * Usage: dtlm watch kfunc-trace --param func=<kernel-function>
 */

fbt::${func}:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: -> ${func}\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::${func}:return
/* @dtlm-predicate */
{
    printf("%s[%d]: <- ${func} = %d\n", execname, pid, arg1);
}
