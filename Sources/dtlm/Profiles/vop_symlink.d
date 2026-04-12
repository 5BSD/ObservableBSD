/* Print every vfs:::vop_symlink event */

vfs::vop_symlink:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_symlink", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
