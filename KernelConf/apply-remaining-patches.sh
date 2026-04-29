#!/bin/sh
#
# apply-remaining-patches.sh — apply the TAILQ_FIRST fix and PSB/timing
# patch to pt.c, then build and reload hwt.ko + pt.ko.
#
# Idempotent: safe to run multiple times.  Each section checks whether
# the change is already applied before modifying the file.
#
# Run as root:
#   doas sh KernelConf/apply-remaining-patches.sh
#
# What this does:
#   1. Removes the broken TAILQ_FIRST restore from pt_backend_enable
#      (caused GPF + cross-thread PT data corruption in multi-thread traces)
#   2. Adds PSB/MTC/CYC timing support to pt_backend_configure
#      (enables bsdtrace -P and -C flags)
#   3. Widens PT_SUPPORTED_FLAGS to include timing control bits
#   4. Builds and reloads hwt.ko and pt.ko
#

PT="/usr/src/sys/amd64/pt/pt.c"

if [ ! -f "$PT" ]; then
    echo "FATAL: $PT not found"
    exit 1
fi

ERRORS=0

# ─────────────────────────────────────────────────────────
# Patch 1: Remove TAILQ_FIRST from pt_backend_enable
# ─────────────────────────────────────────────────────────

echo "=== Patch 1: Remove TAILQ_FIRST from pt_backend_enable ==="

if grep -q 'thr = TAILQ_FIRST.*ctx->threads' "$PT"; then
    cp "$PT" "${PT}.pre-tailq-fix"
    echo "  Backed up to ${PT}.pre-tailq-fix"

    # The broken block is:
    #   struct hwt_thread *thr;
    #   <blank line>
    #   ... KASSERT ...
    #   <blank line>
    #   /*
    #    * Restore the per-CPU context pointer. ...
    #    */
    #   thr = TAILQ_FIRST(&ctx->threads);
    #   if (thr != NULL && thr->private != NULL)
    #       pt_pcpu[cpu_id].ctx = ...;
    #   <blank line>
    #   pt_cpu_start(NULL);
    #
    # Replace the entire function body.  We match from "pt_backend_enable"
    # to the closing brace and rewrite it.

    python3 - "$PT" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

old = '''\
static void
pt_backend_enable(struct hwt_context *ctx, int cpu_id)
{
\tstruct hwt_thread *thr;

\tif (ctx->mode == HWT_MODE_CPU)
\t\treturn;

\tKASSERT(curcpu == cpu_id,
\t    ("%s: attempting to start PT on another cpu", __func__));

\t/*
\t * Restore the per-CPU context pointer.  pt_backend_disable clears
\t * cpu->ctx on every switch-out; we must re-set it here so that
\t * pt_cpu_start can find the tracing context on the new CPU.
\t */
\tthr = TAILQ_FIRST(&ctx->threads);
\tif (thr != NULL && thr->private != NULL)
\t\tpt_pcpu[cpu_id].ctx = (struct pt_ctx *)thr->private;

\tpt_cpu_start(NULL);
\tCPU_SET(cpu_id, &ctx->cpu_map);
}'''

new = '''\
static void
pt_backend_enable(struct hwt_context *ctx, int cpu_id)
{

\tif (ctx->mode == HWT_MODE_CPU)
\t\treturn;

\tKASSERT(curcpu == cpu_id,
\t    ("%s: attempting to start PT on another cpu", __func__));

\t/*
\t * pt_backend_configure() is called by hwt_switch_in() immediately
\t * before this function.  It iterates ctx->threads by thread_id and
\t * sets pt_pcpu[cpu_id].ctx to the correct thread's pt_ctx.
\t *
\t * Do NOT restore cpu->ctx here.  The previous code used
\t * TAILQ_FIRST(&ctx->threads) which always picked thread 0,
\t * clobbering the correct value for other threads.  This caused
\t * xrstors to load the wrong save area (GPF) and PT data to be
\t * written to the wrong thread's buffer (cross-thread contamination).
\t */
\tpt_cpu_start(NULL);
\tCPU_SET(cpu_id, &ctx->cpu_map);
}'''

if old not in src:
    print("  ERROR: could not find the expected TAILQ_FIRST block", file=sys.stderr)
    print("  The function may have already been patched or modified.", file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(src)
print("  Removed TAILQ_FIRST block from pt_backend_enable")
PYEOF

    if [ $? -ne 0 ]; then
        echo "  FAILED — restoring backup"
        cp "${PT}.pre-tailq-fix" "$PT"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "  Already applied (no TAILQ_FIRST in pt_backend_enable)"
fi

# ─────────────────────────────────────────────────────────
# Patch 2: Widen PT_SUPPORTED_FLAGS for timing bits
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Patch 2: Widen PT_SUPPORTED_FLAGS ==="

if grep -q 'RTIT_CTL_TSCEN' "$PT" && grep -A5 'PT_SUPPORTED_FLAGS' "$PT" | grep -q 'RTIT_CTL_TSCEN'; then
    echo "  Already applied (RTIT_CTL_TSCEN found in PT_SUPPORTED_FLAGS)"
else
    python3 - "$PT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

old = '''\
#define PT_SUPPORTED_FLAGS\t\t\t\t\t\t\\
\t(RTIT_CTL_MTCEN | RTIT_CTL_CR3FILTER | RTIT_CTL_DIS_TNT |\t\\
\t    RTIT_CTL_USER | RTIT_CTL_OS | RTIT_CTL_BRANCHEN)'''

new = '''\
#define PT_SUPPORTED_FLAGS\t\t\t\t\t\t\\
\t(RTIT_CTL_MTCEN | RTIT_CTL_CR3FILTER | RTIT_CTL_DIS_TNT |\t\\
\t    RTIT_CTL_USER | RTIT_CTL_OS | RTIT_CTL_BRANCHEN |\t\t\\
\t    RTIT_CTL_TSCEN | RTIT_CTL_CYCEN |\t\t\t\t\\
\t    RTIT_CTL_MTC_FREQ_M |\t\t\t\t\t\\
\t    RTIT_CTL_CYC_THRESH_M | RTIT_CTL_PSB_FREQ_M)'''

if old not in src:
    print("  ERROR: could not find expected PT_SUPPORTED_FLAGS", file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(src)
print("  Widened PT_SUPPORTED_FLAGS to include timing bits")
PYEOF

    if [ $? -ne 0 ]; then
        echo "  FAILED"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ─────────────────────────────────────────────────────────
# Patch 3: Add PSB/MTC/CYC handling to pt_backend_configure
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Patch 3: Add PSB/MTC/CYC to pt_backend_configure ==="

if grep -q 'cfg->psb_freq > 0' "$PT"; then
    echo "  Already applied (cfg->psb_freq found in pt_backend_configure)"
else
    python3 - "$PT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

# Insert the timing validation block right after the
# "/* TODO: support for more config bits. */" comment
# and before the mode switch (if ctx->mode == HWT_MODE_CPU).

marker = '\t/* TODO: support for more config bits. */\n'
insertion_point = marker + '\n\tif (ctx->mode == HWT_MODE_CPU) {'

timing_block = marker + '''
\t/*
\t * PSB frequency: controls how often the hardware emits a PSB
\t * (Packet Stream Boundary) synchronization packet.  The 4-bit
\t * encoding selects powers of 2 from 2K to 32M bytes of output.
\t * Validate against CPUID leaf 0x14 subleaf 1 EBX[31:16] bitmap.
\t */
\tif (cfg->psb_freq > 0) {
\t\tif ((pt_info.l0_ebx & CPUPT_PSB) == 0) {
\t\t\tprintf("%s: CPU does not support configurable PSB\\n",
\t\t\t    __func__);
\t\t\treturn (ENXIO);
\t\t}
\t\tif (cfg->psb_freq > 0xf) {
\t\t\tprintf("%s: psb_freq %u out of range (max 15)\\n",
\t\t\t    __func__, cfg->psb_freq);
\t\t\treturn (EINVAL);
\t\t}
\t\tif (((pt_info.l1_ebx >> CPUPT_PFE_BITMAP_S) &
\t\t    (1 << cfg->psb_freq)) == 0) {
\t\t\tprintf("%s: psb_freq %u not supported by CPU\\n",
\t\t\t    __func__, cfg->psb_freq);
\t\t\treturn (EINVAL);
\t\t}
\t\tcfg->rtit_ctl |= (uint64_t)cfg->psb_freq <<
\t\t    RTIT_CTL_PSB_FREQ_S;
\t}

\t/*
\t * MTC frequency: controls Mini Time Counter packet rate.
\t * Validate against CPUID leaf 0x14 subleaf 1 EAX[31:16] bitmap.
\t * RTIT_CTL_MTCEN must also be set.
\t */
\tif (cfg->mtc_freq > 0) {
\t\tif ((pt_info.l0_ebx & CPUPT_MTC) == 0) {
\t\t\tprintf("%s: CPU does not support MTC packets\\n",
\t\t\t    __func__);
\t\t\treturn (ENXIO);
\t\t}
\t\tif (cfg->mtc_freq > 0xf) {
\t\t\tprintf("%s: mtc_freq %u out of range (max 15)\\n",
\t\t\t    __func__, cfg->mtc_freq);
\t\t\treturn (EINVAL);
\t\t}
\t\tif (((pt_info.l1_eax >> CPUPT_MTC_BITMAP_S) &
\t\t    (1 << cfg->mtc_freq)) == 0) {
\t\t\tprintf("%s: mtc_freq %u not supported by CPU\\n",
\t\t\t    __func__, cfg->mtc_freq);
\t\t\treturn (EINVAL);
\t\t}
\t\tcfg->rtit_ctl |= RTIT_CTL_MTC_FREQ(cfg->mtc_freq);
\t\tcfg->rtit_ctl |= RTIT_CTL_MTCEN;
\t\tcfg->rtit_ctl |= RTIT_CTL_TSCEN;
\t}

\t/*
\t * Cycle-accurate threshold: controls CYC packet granularity.
\t * CPUPT_PSB capability bit covers both PSB and CYC support.
\t * Validate against CPUID leaf 0x14 subleaf 1 EBX[15:0] bitmap.
\t */
\tif (cfg->cyc_thresh > 0) {
\t\tif ((pt_info.l0_ebx & CPUPT_PSB) == 0) {
\t\t\tprintf("%s: CPU does not support cycle-accurate mode\\n",
\t\t\t    __func__);
\t\t\treturn (ENXIO);
\t\t}
\t\tif (cfg->cyc_thresh > 0xf) {
\t\t\tprintf("%s: cyc_thresh %u out of range (max 15)\\n",
\t\t\t    __func__, cfg->cyc_thresh);
\t\t\treturn (EINVAL);
\t\t}
\t\tif ((((pt_info.l1_ebx & CPUPT_CT_BITMAP_M) >>
\t\t    CPUPT_CT_BITMAP_S) & (1 << cfg->cyc_thresh)) == 0) {
\t\t\tprintf("%s: cyc_thresh %u not supported by CPU\\n",
\t\t\t    __func__, cfg->cyc_thresh);
\t\t\treturn (EINVAL);
\t\t}
\t\tcfg->rtit_ctl |= (uint64_t)cfg->cyc_thresh <<
\t\t    RTIT_CTL_CYC_THRESH_S;
\t\tcfg->rtit_ctl |= RTIT_CTL_CYCEN;
\t\tcfg->rtit_ctl |= RTIT_CTL_TSCEN;
\t}

\tif (ctx->mode == HWT_MODE_CPU) {'''

if insertion_point not in src:
    print("  ERROR: could not find insertion point", file=sys.stderr)
    print("  Expected: /* TODO: support for more config bits. */", file=sys.stderr)
    print("  followed by: if (ctx->mode == HWT_MODE_CPU) {", file=sys.stderr)
    sys.exit(1)

src = src.replace(insertion_point, timing_block, 1)
with open(path, 'w') as f:
    f.write(src)
print("  Added PSB/MTC/CYC validation to pt_backend_configure")
PYEOF

    if [ $? -ne 0 ]; then
        echo "  FAILED"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ─────────────────────────────────────────────────────────
# Verify
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Verification ==="

PASS=0
TOTAL=0

check() {
    TOTAL=$((TOTAL + 1))
    if eval "$2"; then
        echo "  OK  $1"
        PASS=$((PASS + 1))
    else
        echo "  BAD $1"
        ERRORS=$((ERRORS + 1))
    fi
}

check "No TAILQ_FIRST code in pt_backend_enable" \
    "! grep -q 'thr = TAILQ_FIRST.*ctx->threads' $PT"

check "pt_cpu_start NULL check" \
    "grep -q 'if (cpu->ctx == NULL)' $PT"

check "pt_send_buffer_record NULL guard" \
    "grep -B3 'pt_fill_buffer_record' $PT | grep -q 'if (ctx == NULL)'"

check "pt_update_buffer reads save area" \
    "grep -q 'pt_ctx_get_ext_area' $PT"

check "PMI handler NULL checks" \
    "grep -A5 'ctx = cpu->ctx;' $PT | grep -q 'pt_topa_status_clear'"

check "pt_backend_stop_op exists" \
    "grep -q 'pt_backend_stop_op' $PT"

check "PT_SUPPORTED_FLAGS has TSCEN" \
    "grep -q 'RTIT_CTL_TSCEN' $PT"

check "PSB freq validation" \
    "grep -q 'cfg->psb_freq' $PT"

check "MTC freq validation" \
    "grep -q 'cfg->mtc_freq' $PT"

check "CYC thresh validation" \
    "grep -q 'cfg->cyc_thresh' $PT"

check "hwt_owner.c TOCTOU fix" \
    "grep -B5 'hwt_contexthash_remove' /usr/src/sys/dev/hwt/hwt_owner.c | grep -q 'ctx->state = 0'"

echo ""
echo "  $PASS/$TOTAL checks passed"

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "ERRORS: $ERRORS — not building.  Fix the issues above first."
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Build and reload
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Building modules ==="
set -e

echo "  Building hwt.ko..."
cd /usr/src/sys/modules/hwt && make clean && make

echo "  Building pt.ko..."
cd /usr/src/sys/modules/pt && make clean && make

echo ""
echo "=== Installing to /boot/GENERIC-HWT/ ==="
OBJDIR="${MAKEOBJDIRPREFIX:-/usr/obj}/usr/src/$(uname -m).$(uname -m)/sys/modules"
cp "$OBJDIR/hwt/hwt.ko" /boot/GENERIC-HWT/hwt.ko
cp "$OBJDIR/pt/pt.ko" /boot/GENERIC-HWT/pt.ko

echo ""
echo "=== Reloading modules ==="
echo "  Unloading old modules..."
kldunload pt 2>/dev/null || true
kldunload hwt 2>/dev/null || true
sleep 1

echo "  Loading patched modules..."
kldload /boot/GENERIC-HWT/hwt.ko
kldload /boot/GENERIC-HWT/pt.ko

echo ""
echo "=== Done ==="
kldstat | grep -E 'hwt\.ko|pt\.ko'
echo ""
echo "Changes applied:"
echo "  1. Removed TAILQ_FIRST from pt_backend_enable (GPF + thread contamination fix)"
echo "  2. Added PSB/MTC/CYC timing support to pt_backend_configure"
echo "  3. Rebuilt and reloaded hwt.ko + pt.ko"
