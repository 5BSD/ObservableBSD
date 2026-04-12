/* Count every syscall by name; print the table on END */

syscall:::entry
/* @dtlm-predicate */
{
    @counts[probefunc] = count();
    /* @dtlm-stack */
    /* @dtlm-ustack */
}

dtrace:::END
{
    printa("%-30s %@d\n", @counts);
}
