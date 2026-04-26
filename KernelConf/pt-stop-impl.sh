#!/bin/sh
# Implement pt_backend_stop and wire it into pt_ops.
# Run as: doas sh KernelConf/pt-stop-impl.sh
set -e

FILE="/usr/src/sys/amd64/pt/pt.c"
cp "$FILE" "${FILE}.pre-stop"

# Find insertion line (before pt_backend_dump)
DUMP_LINE=$(grep -n '^pt_backend_dump(int cpu_id)' "$FILE" | head -1 | cut -d: -f1)
# The "static void" is one line above
INSERT_BEFORE=$((DUMP_LINE - 1))

# Find the .hwt_backend_read line in pt_ops
READ_LINE=$(grep -n '\.hwt_backend_read = pt_backend_read' "$FILE" | head -1 | cut -d: -f1)

echo "Inserting stop functions before line $INSERT_BEFORE"
echo "Adding .hwt_backend_stop before line $READ_LINE"

# Create the new functions
cat > /tmp/pt_stop_funcs.c << 'FUNCS'
/*
 * Stop PT without tearing down the tracing context.
 *
 * Reuse pt_cpu_stop() so the final buffer offset comes from the
 * XSAVE save area via pt_update_buffer().  Reading
 * OUTPUT_MASK_PTRS directly here loses the ToPA page index on the
 * kernels that require the pt_update_buffer() fix.
 */
static void
pt_cpu_stop_preserve_ctx(void *dummy)
{
	struct pt_cpu *cpu;
	struct pt_ctx *ctx;

	cpu = &pt_pcpu[curcpu];
	ctx = cpu->ctx;
	if (ctx == NULL)
		return;

	pt_cpu_stop(NULL);
}

/*
 * HWT backend stop operation.
 *
 * Cleanly stops PT on all active CPUs and records the exact
 * buffer position.  Does not tear down the context, and clears
 * the CPU-mode running latch so HWT_IOC_START can re-arm it.
 */
static void
pt_backend_stop_op(struct hwt_context *ctx)
{
	struct pt_cpu *cpu;
	int cpu_id;

	if (ctx->mode == HWT_MODE_CPU &&
	    atomic_swap_32(&cpu_mode_ctr, 0) == 0)
		return;

	if (CPU_EMPTY(&ctx->cpu_map))
		return;

	CPU_FOREACH_ISSET(cpu_id, &ctx->cpu_map) {
		cpu = &pt_pcpu[cpu_id];
		pt_cpu_set_state(cpu_id, PT_INACTIVE);
		while (atomic_cmpset_int(&cpu->in_pcint_handler, 1, 0))
			;
	}
	smp_rendezvous_cpus(ctx->cpu_map, NULL, pt_cpu_stop_preserve_ctx,
	    NULL, NULL);
}

FUNCS

# Insert the functions before pt_backend_dump
head -n $((INSERT_BEFORE - 1)) "$FILE" > /tmp/pt_new.c
cat /tmp/pt_stop_funcs.c >> /tmp/pt_new.c
tail -n +$INSERT_BEFORE "$FILE" >> /tmp/pt_new.c

# Now add .hwt_backend_stop to pt_ops (line shifted by insertion)
ADDED_LINES=$(wc -l < /tmp/pt_stop_funcs.c)
NEW_READ_LINE=$((READ_LINE + ADDED_LINES))
sed -i '' "${NEW_READ_LINE}i\\
\\	.hwt_backend_stop = pt_backend_stop_op,\\
" /tmp/pt_new.c

cp /tmp/pt_new.c "$FILE"
rm -f /tmp/pt_stop_funcs.c /tmp/pt_new.c

echo "Done. Verify:"
grep -n 'pt_cpu_stop_preserve_ctx\|pt_backend_stop_op\|hwt_backend_stop' "$FILE" | head -10
