/* Print every vfs:::vop_lookup event */

vfs::vop_lookup:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_lookup\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
