/*
 * VFS operation rates — reads, writes, creates, removes per interval.
 *
 * Aggregates VFS-level operations by type and process. Shows
 * the filesystem workload mix. Complement with vfs-latency
 * for per-operation timing.
 */

vfs::vop_read:entry
/* @dtlm-predicate */
{
    @ops[execname, "read"] = count();
}

vfs::vop_write:entry
/* @dtlm-predicate */
{
    @ops[execname, "write"] = count();
}

vfs::vop_create:entry
/* @dtlm-predicate */
{
    @ops[execname, "create"] = count();
}

vfs::vop_remove:entry
/* @dtlm-predicate */
{
    @ops[execname, "remove"] = count();
}

vfs::vop_lookup:entry
/* @dtlm-predicate */
{
    @ops[execname, "lookup"] = count();
}

vfs::vop_readdir:entry
/* @dtlm-predicate */
{
    @ops[execname, "readdir"] = count();
}

dtrace:::END
{
    printf("\n--- VFS operations by process/type ---\n");
    printf("%-20s %-10s %8s\n", "EXECNAME", "OP", "COUNT");
    printa("%-20s %-10s %@8d\n", @ops);
}
