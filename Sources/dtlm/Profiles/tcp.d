/* Print every tcp:::state-change with previous and current state */

tcp:::state-change
/* @dtlm-predicate */
{
    printf("%s[%d]: tcp state %d -> %d\n", execname, pid, args[5]->tcps_state, args[3]->tcps_state);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
