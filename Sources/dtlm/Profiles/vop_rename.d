/* Print every vfs:::vop_rename event */

vfs::vop_rename:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_rename\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
