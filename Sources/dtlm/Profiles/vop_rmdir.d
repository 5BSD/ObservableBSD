/* Print every vfs:::vop_rmdir event */

vfs::vop_rmdir:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_rmdir\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
