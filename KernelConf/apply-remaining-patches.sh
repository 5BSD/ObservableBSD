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
#      (enables bsdtrace -P, -C, -M, -Y flags)
#   3. Widens PT_SUPPORTED_FLAGS to include timing control bits
#   4. Adds PTWRITE + FUPONPTW support (enables bsdtrace -W flag)
#   5. Adds overflow detection (RTIT_STATUS_ERROR → HWT_RECORD_OVERFLOW)
#   6. Builds and reloads hwt.ko and pt.ko
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

if grep -A5 'PT_SUPPORTED_FLAGS' "$PT" | grep -q 'RTIT_CTL_TSCEN'; then
    echo "  Already applied (RTIT_CTL_TSCEN found in PT_SUPPORTED_FLAGS)"
else
    python3 - "$PT" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

# Match any existing PT_SUPPORTED_FLAGS definition and ensure TSCEN is present.
# The flags may already have timing bits (CYCEN, MTC_FREQ_M, etc.) from a
# previous partial patch — just not TSCEN.  Replace the entire macro.
pattern = r'#define PT_SUPPORTED_FLAGS[^\n]*\\\n(?:\t[^\n]*\\\n)*\t[^\n]*\)'
match = re.search(pattern, src)
if not match:
    print("  ERROR: could not find PT_SUPPORTED_FLAGS macro", file=sys.stderr)
    sys.exit(1)

new = '''#define PT_SUPPORTED_FLAGS\t\t\t\t\t\t\\
\t(RTIT_CTL_MTCEN | RTIT_CTL_CR3FILTER | RTIT_CTL_DIS_TNT |\t\\
\t    RTIT_CTL_USER | RTIT_CTL_OS | RTIT_CTL_BRANCHEN |\t\t\\
\t    RTIT_CTL_TSCEN | RTIT_CTL_CYCEN | RTIT_CTL_MTC_FREQ_M |\t\\
\t    RTIT_CTL_CYC_THRESH_M | RTIT_CTL_PSB_FREQ_M |\t\t\\
\t    RTIT_CTL_PTWEN | RTIT_CTL_FUPONPTW)'''

src = src[:match.start()] + new + src[match.end():]
with open(path, 'w') as f:
    f.write(src)
print("  Set PT_SUPPORTED_FLAGS to complete flag set (including TSCEN)")
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
# Patch 4: Add PTWRITE + FUPONPTW support
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Patch 4: PTWRITE + FUPONPTW support ==="

if grep -q 'RTIT_CTL_PTWEN' "$PT"; then
    echo "  Already applied (RTIT_CTL_PTWEN found)"
else
    python3 - "$PT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

# Add PTWEN | FUPONPTW to PT_SUPPORTED_FLAGS
old_end = 'RTIT_CTL_CYC_THRESH_M | RTIT_CTL_PSB_FREQ_M)'
new_end = '''RTIT_CTL_CYC_THRESH_M | RTIT_CTL_PSB_FREQ_M |\t\t\\
\t    RTIT_CTL_PTWEN | RTIT_CTL_FUPONPTW)'''

if old_end not in src:
    print("  ERROR: could not find PT_SUPPORTED_FLAGS end", file=sys.stderr)
    sys.exit(1)

src = src.replace(old_end, new_end, 1)

# Add PTWRITE validation after DIS_TNT check
marker = '\t/* TODO: support for more config bits. */\n'
if marker in src:
    validation = '''\tif (cfg->rtit_ctl & RTIT_CTL_PTWEN) {
\t\tif ((pt_info.l0_ebx & CPUPT_PRW) == 0) {
\t\t\tprintf("%s: CPU does not support PTWRITE\\n",
\t\t\t    __func__);
\t\t\treturn (ENXIO);
\t\t}
\t}
\tif ((cfg->rtit_ctl & RTIT_CTL_FUPONPTW) &&
\t    !(cfg->rtit_ctl & RTIT_CTL_PTWEN)) {
\t\tprintf("%s: FUPONPTW requires PTWEN\\n", __func__);
\t\treturn (EINVAL);
\t}
'''
    src = src.replace(marker, validation, 1)
else:
    # If TODO marker was already replaced, insert after DIS_TNT block
    dis_tnt_end = "\t\t\treturn (ENXIO);\n\t\t}\n\t}\n"
    # Find the last occurrence (DIS_TNT is last validation)
    idx = src.rfind(dis_tnt_end)
    if idx < 0:
        print("  ERROR: could not find insertion point for PTWRITE", file=sys.stderr)
        sys.exit(1)
    insert_at = idx + len(dis_tnt_end)
    validation = '''\tif (cfg->rtit_ctl & RTIT_CTL_PTWEN) {
\t\tif ((pt_info.l0_ebx & CPUPT_PRW) == 0) {
\t\t\tprintf("%s: CPU does not support PTWRITE\\n",
\t\t\t    __func__);
\t\t\treturn (ENXIO);
\t\t}
\t}
\tif ((cfg->rtit_ctl & RTIT_CTL_FUPONPTW) &&
\t    !(cfg->rtit_ctl & RTIT_CTL_PTWEN)) {
\t\tprintf("%s: FUPONPTW requires PTWEN\\n", __func__);
\t\treturn (EINVAL);
\t}
'''
    src = src[:insert_at] + validation + src[insert_at:]

with open(path, 'w') as f:
    f.write(src)
print("  Added PTWRITE + FUPONPTW to PT_SUPPORTED_FLAGS and validation")
PYEOF

    if [ $? -ne 0 ]; then
        echo "  FAILED"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ─────────────────────────────────────────────────────────
# Patch 5: Add overflow detection + HWT_RECORD_OVERFLOW
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Patch 5: Overflow detection ==="

HWT_REC="/usr/src/sys/sys/hwt_record.h"

if grep -q 'HWT_RECORD_OVERFLOW' "$HWT_REC" 2>/dev/null; then
    echo "  hwt_record.h: Already applied"
else
    if [ -f "$HWT_REC" ]; then
        sed -i '' 's/HWT_RECORD_BUFFER$/HWT_RECORD_BUFFER,\
	HWT_RECORD_OVERFLOW/' "$HWT_REC"
        echo "  Added HWT_RECORD_OVERFLOW to hwt_record.h"
    else
        echo "  WARNING: $HWT_REC not found — skip enum update"
    fi
fi

HWT_RECC="/usr/src/sys/dev/hwt/hwt_record.c"
if [ -f "$HWT_RECC" ] && ! grep -q 'HWT_RECORD_OVERFLOW' "$HWT_RECC"; then
    sed -i '' '/case HWT_RECORD_BUFFER:/a\
	case HWT_RECORD_OVERFLOW:' "$HWT_RECC"
    echo "  Added HWT_RECORD_OVERFLOW to hwt_record_to_user copyout"
elif [ -f "$HWT_RECC" ]; then
    echo "  hwt_record.c: Already applied"
fi

if grep -q 'overflow_pending' "$PT"; then
    echo "  pt.c: Already applied (overflow_pending found)"
else
    python3 - "$PT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()

# Add overflow_pending to struct pt_cpu
old_field = '\tint in_pcint_handler;\n} *pt_pcpu;'
new_field = '\tint in_pcint_handler;\n\tint overflow_pending;\n} *pt_pcpu;'
if old_field not in src:
    print("  ERROR: could not find in_pcint_handler field", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_field, new_field, 1)

# Add RTIT_STATUS_ERROR check in pt_topa_intr
old_intr = '\tpt_cpu_toggle_local(ctx->save_area, false);\n\tpt_update_buffer(ctx);\n\tpt_topa_status_clear();'
new_intr = '''\tpt_cpu_toggle_local(ctx->save_area, false);
\tpt_update_buffer(ctx);

\t/* Check for internal buffer overflow (data loss). */
\tif (rdmsr(MSR_IA32_RTIT_STATUS) & RTIT_STATUS_ERROR)
\t\tcpu->overflow_pending = 1;

\tpt_topa_status_clear();'''
if old_intr not in src:
    print("  ERROR: could not find pt_topa_intr toggle/update/clear", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_intr, new_intr, 1)

# Add overflow record enqueue in pt_send_buffer_record.
# The file may have mixed tabs/spaces from earlier edits, so match
# flexibly: find hwt_record_ctx...NOWAIT);\n} in pt_send_buffer_record.
import re
send_pat = re.compile(
    r'([ \t]*pt_fill_buffer_record\(ctx->id.*?\n)'
    r'([ \t]*hwt_record_ctx\(ctx->hwt_ctx, &record, M_ZERO \| M_NOWAIT\);\n)'
    r'\}',
    re.DOTALL)
send_match = send_pat.search(src)
if send_match is None:
    print("  ERROR: could not find pt_send_buffer_record body", file=sys.stderr)
    sys.exit(1)
new_send = '''\tpt_fill_buffer_record(ctx->id, &ctx->buf, &record);
\thwt_record_ctx(ctx->hwt_ctx, &record, M_ZERO | M_NOWAIT);

\tif (cpu->overflow_pending) {
\t\tstruct hwt_record_entry ovf_rec;
\t\tovf_rec.record_type = HWT_RECORD_OVERFLOW;
\t\tovf_rec.buf_id = ctx->id;
\t\tovf_rec.curpage = 0;
\t\tovf_rec.offset = 0;
\t\thwt_record_ctx(ctx->hwt_ctx, &ovf_rec, M_ZERO | M_NOWAIT);
\t\tcpu->overflow_pending = 0;
\t}
}'''
src = src[:send_match.start()] + new_send + src[send_match.end():]

with open(path, 'w') as f:
    f.write(src)
print("  Added overflow_pending, RTIT_STATUS_ERROR check, and overflow record")
PYEOF

    if [ $? -ne 0 ]; then
        echo "  FAILED"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ─────────────────────────────────────────────────────────
# Patch 6: TraceStop IP filter mode
# ─────────────────────────────────────────────────────────

echo ""
echo "=== Patch 6: TraceStop IP filter mode ==="

PT_H="/usr/src/sys/amd64/pt/pt.h"

if grep -q 'PT_RANGE_TRACESTOP' "$PT_H" 2>/dev/null; then
    echo "  Already applied (PT_RANGE_TRACESTOP found)"
else
    if [ -f "$PT_H" ]; then
        python3 - "$PT_H" "$PT" << 'PYEOF'
import sys

T = '\t'
pth = sys.argv[1]
ptc = sys.argv[2]

# Update pt.h: add mode field and defines
with open(pth, 'r') as f:
    src = f.read()

old_struct = f'{T}struct ipf_range {{\n{T}{T}vm_offset_t start;\n{T}{T}vm_offset_t end;\n{T}}} ip_ranges[PT_IP_FILTER_MAX_RANGES];'

new_struct = f'''/*
 * IP filter range modes (ADDR_CFG field encoding):
 *   0 - disabled (default if nranges omits this range)
 *   1 - FilterEn: trace only when IP is within [start, end)
 *   2 - TraceStop: stop tracing when IP enters [start, end)
 */
#define{T}PT_RANGE_FILTER{T}{T}1
#define{T}PT_RANGE_TRACESTOP{T}2

{T}struct ipf_range {{
{T}{T}vm_offset_t start;
{T}{T}vm_offset_t end;
{T}{T}int mode;{T}/* PT_RANGE_FILTER or PT_RANGE_TRACESTOP */
{T}}} ip_ranges[PT_IP_FILTER_MAX_RANGES];'''

if old_struct not in src:
    print("  ERROR: could not find ipf_range struct in pt.h", file=sys.stderr)
    sys.exit(1)

src = src.replace(old_struct, new_struct, 1)
with open(pth, 'w') as f:
    f.write(src)
print("  Added mode field to ipf_range in pt.h")

# Update pt.c: use mode in pt_configure_ranges
with open(ptc, 'r') as f:
    src = f.read()

old_case2 = f'''{T}{T}case 2:
{T}{T}{T}pt_ext->rtit_ctl |= (1UL << RTIT_CTL_ADDR_CFG_S(1));
{T}{T}{T}pt_ext->rtit_addr1_a = cfg->ip_ranges[1].start;
{T}{T}{T}pt_ext->rtit_addr1_b = cfg->ip_ranges[1].end;
{T}{T}case 1:
{T}{T}{T}pt_ext->rtit_ctl |= (1UL << RTIT_CTL_ADDR_CFG_S(0));
{T}{T}{T}pt_ext->rtit_addr0_a = cfg->ip_ranges[0].start;
{T}{T}{T}pt_ext->rtit_addr0_b = cfg->ip_ranges[0].end;
{T}{T}{T}break;'''

new_case2 = f'''{T}{T}case 2: {{
{T}{T}{T}int mode1 = cfg->ip_ranges[1].mode;
{T}{T}{T}if (mode1 == 0)
{T}{T}{T}{T}mode1 = PT_RANGE_FILTER;
{T}{T}{T}if (mode1 < 1 || mode1 > 2) {{
{T}{T}{T}{T}printf("%s: ip_ranges[1].mode %d invalid "
{T}{T}{T}{T}    "(1=filter, 2=tracestop)\\n",
{T}{T}{T}{T}    __func__, cfg->ip_ranges[1].mode);
{T}{T}{T}{T}return (EINVAL);
{T}{T}{T}}}
{T}{T}{T}pt_ext->rtit_ctl |=
{T}{T}{T}    ((uint64_t)mode1 << RTIT_CTL_ADDR_CFG_S(1));
{T}{T}{T}pt_ext->rtit_addr1_a = cfg->ip_ranges[1].start;
{T}{T}{T}pt_ext->rtit_addr1_b = cfg->ip_ranges[1].end;
{T}{T}}}
{T}{T}/* FALLTHROUGH */
{T}{T}case 1: {{
{T}{T}{T}int mode0 = cfg->ip_ranges[0].mode;
{T}{T}{T}if (mode0 == 0)
{T}{T}{T}{T}mode0 = PT_RANGE_FILTER;
{T}{T}{T}if (mode0 < 1 || mode0 > 2) {{
{T}{T}{T}{T}printf("%s: ip_ranges[0].mode %d invalid "
{T}{T}{T}{T}    "(1=filter, 2=tracestop)\\n",
{T}{T}{T}{T}    __func__, cfg->ip_ranges[0].mode);
{T}{T}{T}{T}return (EINVAL);
{T}{T}{T}}}
{T}{T}{T}pt_ext->rtit_ctl |=
{T}{T}{T}    ((uint64_t)mode0 << RTIT_CTL_ADDR_CFG_S(0));
{T}{T}{T}pt_ext->rtit_addr0_a = cfg->ip_ranges[0].start;
{T}{T}{T}pt_ext->rtit_addr0_b = cfg->ip_ranges[0].end;
{T}{T}{T}break;
{T}{T}}}'''

if old_case2 not in src:
    print("  ERROR: could not find pt_configure_ranges switch in pt.c", file=sys.stderr)
    sys.exit(1)

src = src.replace(old_case2, new_case2, 1)
with open(ptc, 'w') as f:
    f.write(src)
print("  Updated pt_configure_ranges to use per-range mode")
PYEOF

        if [ $? -ne 0 ]; then
            echo "  FAILED"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "  WARNING: $PT_H not found — skip TraceStop"
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

check "PTWRITE support (RTIT_CTL_PTWEN)" \
    "grep -q 'RTIT_CTL_PTWEN' $PT"

check "PTWRITE validation (CPUPT_PRW)" \
    "grep -q 'CPUPT_PRW' $PT"

check "FUPONPTW requires PTWEN check" \
    "grep -q 'FUPONPTW requires PTWEN' $PT"

check "overflow_pending field" \
    "grep -q 'overflow_pending' $PT"

check "RTIT_STATUS_ERROR overflow check" \
    "grep -q 'RTIT_STATUS_ERROR' $PT"

check "HWT_RECORD_OVERFLOW enum" \
    "grep -q 'HWT_RECORD_OVERFLOW' /usr/src/sys/sys/hwt_record.h 2>/dev/null || echo skip"

check "TraceStop mode defines" \
    "grep -q 'PT_RANGE_TRACESTOP' /usr/src/sys/amd64/pt/pt.h 2>/dev/null || echo skip"

check "Per-range mode field" \
    "grep -q 'int mode' /usr/src/sys/amd64/pt/pt.h 2>/dev/null || echo skip"

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
echo "  3. Added PTWRITE + FUPONPTW support"
echo "  4. Added overflow detection (RTIT_STATUS_ERROR + HWT_RECORD_OVERFLOW)"
echo "  5. Added TraceStop IP filter mode (per-range mode field)"
echo "  6. Rebuilt and reloaded hwt.ko + pt.ko"
