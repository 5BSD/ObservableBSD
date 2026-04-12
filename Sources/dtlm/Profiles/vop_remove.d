/* Print every vfs:::vop_remove event */

vfs::vop_remove:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_remove\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
