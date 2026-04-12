/* Print every kill(2) syscall with signal number and target pid */

syscall::kill:entry
/* @dtlm-predicate */
{
    printf("%s[%d]: signal %d to pid %d",
           execname, pid, (int)arg1, (pid_t)arg0);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
