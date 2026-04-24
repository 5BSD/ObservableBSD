/*
 * Device attach/detach events via devd.
 *
 * Traces device_attach and device_detach kernel calls to
 * show hardware hotplug events. Useful for USB device
 * monitoring and hardware audit logging.
 */

fbt::device_attach:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: device attach\n", execname, pid);
    @attaches[execname] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

fbt::device_detach:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: device detach\n", execname, pid);
    @detaches[execname] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

dtrace:::END
{
    printf("\n--- Device attaches ---\n");
    printa("%-30s %@d\n", @attaches);
    printf("\n--- Device detaches ---\n");
    printa("%-30s %@d\n", @detaches);
}
