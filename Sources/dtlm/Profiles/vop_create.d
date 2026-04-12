/* Print every vfs:::vop_create event */

vfs::vop_create:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: vop_create\n", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
