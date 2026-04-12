/* KINST — trace one instruction inside a kernel function */
/* Usage: dtlm watch kinst --param func=<name> --param offset=<bytes> */

kinst::${func}:${offset}
/* @dtlm-predicate */
{
    printf("%s[%d]: ${func}+${offset}", execname, pid);
    /* @dtlm-stack */
    /* @dtlm-ustack */
}
