/*
 * Unix domain socket FD/credential passing audit.
 *
 * Traces sendmsg/recvmsg on AF_UNIX sockets to detect
 * SCM_RIGHTS (file descriptor passing) and credential
 * passing activity. Shows which processes exchange file
 * descriptors over Unix sockets.
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
