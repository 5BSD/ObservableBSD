/*
 * Trace a specific user-space function in a process.
 * Usage: dtlm watch func-trace --param pid=<pid> --param func=<function>
 */

pid${pid}::${func}:entry
{
    printf("%s[%d]: -> ${func}\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

pid${pid}::${func}:return
{
    printf("%s[%d]: <- ${func} = %d\n", execname, pid, arg1);
}
