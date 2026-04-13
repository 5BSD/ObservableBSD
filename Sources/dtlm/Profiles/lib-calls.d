/*
 * Trace calls to a shared library function across a process.
 * Usage: dtlm watch lib-calls --param pid=<pid> --param lib=<lib> --param func=<func>
 * Example: dtlm watch lib-calls --param pid=1234 --param lib=libc.so.7 --param func=connect
 */

pid${pid}:${lib}:${func}:entry
{
    printf("%s[%d]: ${lib}:${func} entry\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

pid${pid}:${lib}:${func}:return
{
    printf("%s[%d]: ${lib}:${func} return = %d\n", execname, pid, arg1);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
