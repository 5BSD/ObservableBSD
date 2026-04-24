/*
 * OpenEndpointSecurity file events — vnode operation checks.
 *
 * Traces OES file-related MAC hooks: open, read, write, create,
 * unlink, rename, link. Shows file access patterns through the
 * OES security layer. Requires oes.ko loaded.
 */

fbt::oes_mac_vnode_check_open:entry
/* @dtlm-predicate */
{
    @file_ops[execname, "open"] = count();
}

fbt::oes_mac_vnode_check_read:entry
/* @dtlm-predicate */
{
    @file_ops[execname, "read"] = count();
}

fbt::oes_mac_vnode_check_write:entry
/* @dtlm-predicate */
{
    @file_ops[execname, "write"] = count();
}

fbt::oes_mac_vnode_check_create:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: OES file create check\n", execname, pid);
    @file_ops[execname, "create"] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::oes_mac_vnode_check_unlink:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: OES file unlink check\n", execname, pid);
    @file_ops[execname, "unlink"] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::oes_mac_vnode_check_rename_from:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: OES file rename check\n", execname, pid);
    @file_ops[execname, "rename"] = count();
}

fbt::oes_mac_vnode_check_link:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: OES file link check\n", execname, pid);
    @file_ops[execname, "link"] = count();
}

dtrace:::END
{
    printf("\n--- OES file checks by process/op ---\n");
    printf("%-20s %-10s %8s\n", "EXECNAME", "OP", "COUNT");
    printa("%-20s %-10s %@8d\n", @file_ops);
}
