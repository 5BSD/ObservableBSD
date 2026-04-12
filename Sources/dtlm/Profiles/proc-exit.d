/* Print every proc:::exit event with the exit reason */

proc:::exit
/* @dtlm-predicate */
{
    printf("%s[%d]: exit (reason=%d)", execname, pid, (int)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
