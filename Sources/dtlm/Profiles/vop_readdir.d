/* Print every vfs:::vop_readdir event */

vfs::vop_readdir:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_readdir\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
