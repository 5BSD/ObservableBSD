/* Print every vfs:::vop_mkdir event */

vfs::vop_mkdir:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_mkdir", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
