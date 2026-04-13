/*
 * sendmsg/recvmsg activity by process.
 *
 * Traces sendmsg and recvmsg syscalls with byte counts.
 * Useful for identifying IPC-heavy processes. Note: captures
 * all sendmsg/recvmsg calls regardless of address family —
 * does not distinguish AF_UNIX from AF_INET or inspect
 * ancillary data (SCM_RIGHTS).
 */

syscall::sendmsg:entry
/* @dtlm-predicate */
{
    self->sendmsg_fd = arg0;
}

syscall::sendmsg:return
/self->sendmsg_fd && arg1 >= 0/
{
    printf("%s[%d]: sendmsg fd=%d bytes=%d\n",
        execname, pid, self->sendmsg_fd, arg1);
    @sends[execname] = count();
    self->sendmsg_fd = 0;
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::sendmsg:return
/self->sendmsg_fd/
{
    self->sendmsg_fd = 0;
}

syscall::recvmsg:entry
/* @dtlm-predicate */
{
    self->recvmsg_fd = arg0;
}

syscall::recvmsg:return
/self->recvmsg_fd && arg1 >= 0/
{
    printf("%s[%d]: recvmsg fd=%d bytes=%d\n",
        execname, pid, self->recvmsg_fd, arg1);
    @recvs[execname] = count();
    self->recvmsg_fd = 0;
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

syscall::recvmsg:return
/self->recvmsg_fd/
{
    self->recvmsg_fd = 0;
}

dtrace:::END
{
    printf("\n--- sendmsg count by process ---\n");
    printa("%-30s %@d\n", @sends);
    printf("\n--- recvmsg count by process ---\n");
    printa("%-30s %@d\n", @recvs);
}
