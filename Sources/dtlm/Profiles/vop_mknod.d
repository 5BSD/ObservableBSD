/* Print every vfs:::vop_mknod event */

vfs::vop_mknod:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_mknod\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
