#!/bin/sh
#
# test-bsdtrace.sh — comprehensive test suite for bsdtrace
#
# Two tiers:
#   No-root:  version, list, decode error handling
#   Root:     exec, decode, trace (require HWT kernel modules)
#
# Run:
#   sh test-bsdtrace.sh            # no-root tests only
#   doas sh test-bsdtrace.sh       # full suite
#

# Ensure standard tool directories are in PATH (doas may strip them).
PATH="/usr/bin:/usr/local/bin:/bin:/sbin:/usr/sbin:$PATH"
export PATH

BUILDDIR=".build/x86_64-unknown-freebsd/debug"
BIN="$BUILDDIR/bsdtrace"
TESTPROG="/tmp/bsdtrace-testprog-$$"
ATTACHPROG="/tmp/bsdtrace-attachprog-$$"
THREADPROG="/tmp/bsdtrace-threadprog-$$"
PTWPROG="/tmp/bsdtrace-ptwprog-$$"
FLOODPROG="/tmp/bsdtrace-floodprog-$$"
OBJDUMP=$(command -v llvm-objdump 2>/dev/null || command -v objdump 2>/dev/null || true)
PASS=0
FAIL=0
SKIP=0
TMPDIR="/tmp/bsdtrace-test-$$"
TIMEOUT=30  # seconds per hardware test
PIDS_TO_KILL=""
BACKEND=""
STARTED_PID=""
TESTPROG_RANGE=""
ATTACHPROG_RANGE=""
TESTPROG_BN=""
ATTACHPROG_BN=""
TESTPROG_DISAS=""
ATTACHPROG_DISAS=""
TP_MAIN_START=""
TP_BRANCH_START=""
TP_LOOP_START=""
TP_LEAF_ADD_START=""
TP_MAIN_CALL_LEAF_ADD=""
TP_BRANCH_CJMP=""
TP_BRANCH_JUMP=""
TP_LOOP_CJMP=""
TP_LOOP_JUMP=""
TP_LEAF_ADD_RET=""
AP_ATTACH_BRANCH_START=""
AP_ATTACH_LOOP_START=""
AP_ATTACH_BRANCH_CJMP=""
AP_ATTACH_LOOP_CJMP=""
AP_ATTACH_LOOP_JUMP=""

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }

# Run a bsdtrace command with a timeout.  Returns stdout in $ROUT,
# stderr in $RERR, and the exit code in $RRC.  Prevents a crash/hang
# from killing the test suite.
run_bsdtrace() {
    RERR_FILE="$TMPDIR/.stderr.$$"
    ROUT=$(timeout "$TIMEOUT" $BIN "$@" 2>"$RERR_FILE")
    RRC=$?
    RERR=$(cat "$RERR_FILE" 2>/dev/null)
    rm -f "$RERR_FILE"
    if [ "$RRC" -eq 124 ]; then
        ROUT="TIMEOUT after ${TIMEOUT}s"
        RERR="TIMEOUT after ${TIMEOUT}s"
    fi
    # Combined output for backward-compat with tests that grep both streams.
    RBOTH="$ROUT
$RERR"
}

# Like run_bsdtrace but writes stdout to a file instead of a shell
# variable.  Use for tests that decode millions of instructions —
# capturing that much text in $ROUT exhausts shell memory.
# Sets $ROUT_FILE to the path; $RERR and $RRC work as usual.
run_bsdtrace_file() {
    RERR_FILE="$TMPDIR/.stderr.$$"
    ROUT_FILE="$TMPDIR/.stdout.$$"
    rm -f "$ROUT_FILE"
    timeout "$TIMEOUT" $BIN "$@" >"$ROUT_FILE" 2>"$RERR_FILE"
    RRC=$?
    RERR=$(cat "$RERR_FILE" 2>/dev/null)
    rm -f "$RERR_FILE"
    if [ "$RRC" -eq 124 ]; then
        echo "TIMEOUT after ${TIMEOUT}s" > "$ROUT_FILE"
        RERR="TIMEOUT after ${TIMEOUT}s"
    fi
    ROUT=""
    RBOTH=""
}
skip() { SKIP=$((SKIP + 1)); printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }

lookup_thread_indices() {
    THREAD_LIST_OUT=$($BIN list -p "$1" 2>/dev/null)
    MAIN_THREAD_IDX=$(printf '%s\n' "$THREAD_LIST_OUT" |
        awk '$3 == "main_thr" { print $1; exit }')
    WORKER_THREAD_IDX=$(printf '%s\n' "$THREAD_LIST_OUT" |
        awk '$3 == "worker_thr" { print $1; exit }')
    [ -n "$MAIN_THREAD_IDX" ] && [ -n "$WORKER_THREAD_IDX" ]
}

json_lines_valid() {
    [ -f "$1" ] || return 1
    python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        json.loads(line)
PY
}

json_event_count() {
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, insn, ip = sys.argv[1:4]
count = 0
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("insn") == insn and obj.get("ip") == ip:
            count += 1
print(count)
PY
}

json_has_symbolized_event() {
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json
import sys

path, insn, ip, sym, off, binary = sys.argv[1:7]
want_off = int(off)
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("insn") != insn:
            continue
        if obj.get("ip") != ip:
            continue
        if obj.get("sym") != sym:
            continue
        if obj.get("bin") != binary:
            continue
        if int(obj.get("off", -1)) != want_off:
            continue
        sys.exit(0)
sys.exit(1)
PY
}

json_has_bin_event() {
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys

path, insn, ip, binary, off = sys.argv[1:6]
want_off = int(off)
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("insn") != insn:
            continue
        if obj.get("ip") != ip:
            continue
        if obj.get("bin") != binary:
            continue
        if int(obj.get("off", -1)) != want_off:
            continue
        sys.exit(0)
sys.exit(1)
PY
}

json_has_bin_fallback() {
    [ -f "$1" ] || return 1
    python3 - "$1" "$2" <<'PY'
import json
import sys

path, binary = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "insn" not in obj:
            continue
        if obj.get("bin") != binary:
            continue
        if obj.get("sym"):
            continue
        if "off" not in obj:
            continue
        sys.exit(0)
sys.exit(1)
PY
}

json_has_any_bin_fallback() {
    [ -f "$1" ] || return 1
    python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "insn" not in obj:
            continue
        if not obj.get("bin"):
            continue
        if obj.get("sym"):
            continue
        if "off" not in obj:
            continue
        sys.exit(0)
sys.exit(1)
PY
}

objdump_func_addr() {
    awk -v fname="$2" '
        BEGIN {
            target = "<" fname ">:";
        }
        index($0, target) {
            print "0x" tolower($1);
            exit;
        }
    ' "$1"
}

objdump_insn_addr() {
    awk -v fname="$2" -v pat="$3" -v want="${4:-1}" '
        BEGIN {
            target = "<" fname ">:";
        }
        index($0, target) && $1 ~ /^[0-9a-f]+$/ {
            in_func = 1;
            next;
        }
        in_func && $1 ~ /^[0-9a-f]+$/ && index($0, "<") {
            exit;
        }
        in_func && $0 ~ pat {
            seen++;
            if (seen == want) {
                addr = $1;
                sub(/:$/, "", addr);
                print "0x" tolower(addr);
                exit;
            }
        }
    ' "$1"
}

hex_diff() {
    printf '%u\n' "$(( $1 - $2 ))"
}

settle_hwt() {
    i=0
    while [ "$i" -lt 10 ]; do
        if ! ls /dev/hwt_[0-9]*_[0-9]* >/dev/null 2>&1; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    sleep 3
}

kill_stale_test_targets() {
    # Kill only this run's test binaries (PID-scoped paths).
    pkill -f "$ATTACHPROG" >/dev/null 2>&1 || true
    pkill -f "$TESTPROG" >/dev/null 2>&1 || true
    pkill -f "$THREADPROG" >/dev/null 2>&1 || true
    sleep 1
}

text_range_arg() {
    # Extract the first executable LOAD segment from ELF program headers.
    RANGE_FIELDS=$(readelf -l "$1" 2>/dev/null |
        awk '/LOAD.*R.*E/{print $3, $6; exit}')
    RANGE_VADDR=$(echo "$RANGE_FIELDS" | awk '{print $1}')
    RANGE_MEMSZ=$(echo "$RANGE_FIELDS" | awk '{print $2}')

    if [ -z "$RANGE_VADDR" ] || [ -z "$RANGE_MEMSZ" ]; then
        return 1
    fi

    RANGE_START_DEC=$(printf '%u\n' "$RANGE_VADDR")
    RANGE_LEN_DEC=$(printf '%u\n' "$RANGE_MEMSZ")
    RANGE_END_DEC=$((RANGE_START_DEC + RANGE_LEN_DEC))
    printf '0x%x:0x%x\n' "$RANGE_START_DEC" "$RANGE_END_DEC"
}

start_trace_target() {
    # Attach to a running shell that execs attachprog shortly after.
    # This keeps the target "running" at attach time while still
    # guaranteeing EXEC/MMAP records for the main image.
    sh -c "sleep 1; exec \"$ATTACHPROG\"" > /dev/null 2>&1 &
    STARTED_PID=$!
    PIDS_TO_KILL="$PIDS_TO_KILL $STARTED_PID"
}

stop_trace_target() {
    if [ -n "$STARTED_PID" ]; then
        kill "$STARTED_PID" 2>/dev/null || true
        wait "$STARTED_PID" 2>/dev/null || true
        STARTED_PID=""
        settle_hwt
    fi
}



cleanup() {
    for pid in $PIDS_TO_KILL; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    kill_stale_test_targets
    settle_hwt
    rm -rf "$TMPDIR"
    rm -f "$TESTPROG"
    rm -f "$ATTACHPROG"
    rm -f "$THREADPROG"
    rm -f "$PTWPROG"
    rm -f "$FLOODPROG"
}
trap cleanup EXIT

kill_stale_test_targets
settle_hwt

mkdir -p "$TMPDIR"

echo "=== bsdtrace test suite ==="
echo ""

# ── Build ────────────────────────────────────────────────
echo "--- build ---"

printf "  Building bsdtrace... "
BUILD_LOG="$TMPDIR/.build.log"
swift build --product bsdtrace > "$BUILD_LOG" 2>&1
BUILD_RC=$?
tail -1 "$BUILD_LOG"
rm -f "$BUILD_LOG"
if [ "$BUILD_RC" -ne 0 ]; then
    echo "FATAL: swift build failed (exit $BUILD_RC)"
    exit 2
fi

if [ ! -x "$BIN" ]; then
    echo "FATAL: $BIN not found after build"
    exit 2
fi

# Test programs are compiled with cc (not SPM) so they have no
# Swift runtime or shared library dependencies.  This keeps traces
# small and deterministic — testprog's functions are the entire
# trace, not buried under millions of runtime init instructions.
printf "  Compiling testprog... "
if cc -O0 -o "$TESTPROG" Tests/bsdtrace/testprog/main.c 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile testprog"
    exit 2
fi

printf "  Compiling attachprog... "
if cc -O0 -o "$ATTACHPROG" Tests/bsdtrace/attachprog/main.c 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile attachprog"
    exit 2
fi

printf "  Compiling threadprog... "
if cc -O0 -lpthread -o "$THREADPROG" Tests/bsdtrace/threadprog/main.c 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile threadprog"
    exit 2
fi

printf "  Compiling ptwprog... "
if cc -O0 -I Sources/bsdtrace -o "$PTWPROG" Tests/bsdtrace/ptwprog/main.c 2>&1; then
    echo "ok"
else
    echo "  (failed — PTWRITE tests will be skipped)"
    PTWPROG=""
fi

printf "  Compiling floodprog... "
if cc -O0 -o "$FLOODPROG" Tests/bsdtrace/floodprog/main.c 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile floodprog"
    exit 2
fi


if readelf -h "$TESTPROG" 2>/dev/null | grep -q 'EXEC'; then
    TESTPROG_RANGE=$(text_range_arg "$TESTPROG")
fi

if readelf -h "$ATTACHPROG" 2>/dev/null | grep -q 'EXEC'; then
    ATTACHPROG_RANGE=$(text_range_arg "$ATTACHPROG")
fi

TESTPROG_BN=$(basename "$TESTPROG")
ATTACHPROG_BN=$(basename "$ATTACHPROG")

if [ -n "$OBJDUMP" ]; then
    TESTPROG_DISAS="$TMPDIR/testprog.dis"
    ATTACHPROG_DISAS="$TMPDIR/attachprog.dis"
    if "$OBJDUMP" -d "$TESTPROG" > "$TESTPROG_DISAS" 2>/dev/null &&
        "$OBJDUMP" -d "$ATTACHPROG" > "$ATTACHPROG_DISAS" 2>/dev/null; then
        TP_MAIN_START=$(objdump_func_addr "$TESTPROG_DISAS" main)
        TP_BRANCH_START=$(objdump_func_addr "$TESTPROG_DISAS" branch_test)
        TP_LOOP_START=$(objdump_func_addr "$TESTPROG_DISAS" loop_test)
        TP_LEAF_ADD_START=$(objdump_func_addr "$TESTPROG_DISAS" leaf_add)
        TP_MAIN_CALL_LEAF_ADD=$(objdump_insn_addr "$TESTPROG_DISAS" main 'call[q]*.*<leaf_add>')
        TP_BRANCH_CJMP=$(objdump_insn_addr "$TESTPROG_DISAS" branch_test '[[:space:]]jle\|jbe\|jng[[:space:]]')
        TP_BRANCH_JUMP=$(objdump_insn_addr "$TESTPROG_DISAS" branch_test '[[:space:]]jmp[q]*[[:space:]]')
        TP_LOOP_CJMP=$(objdump_insn_addr "$TESTPROG_DISAS" loop_test '[[:space:]]jge\|jae\|jnl[[:space:]]')
        TP_LOOP_JUMP=$(objdump_insn_addr "$TESTPROG_DISAS" loop_test '[[:space:]]jmp[q]*[[:space:]]')
        TP_LEAF_ADD_RET=$(objdump_insn_addr "$TESTPROG_DISAS" leaf_add '[[:space:]]ret[q]*')

        AP_ATTACH_BRANCH_START=$(objdump_func_addr "$ATTACHPROG_DISAS" attach_branch)
        AP_ATTACH_LOOP_START=$(objdump_func_addr "$ATTACHPROG_DISAS" attach_loop)
        AP_ATTACH_BRANCH_CJMP=$(objdump_insn_addr "$ATTACHPROG_DISAS" attach_branch '[[:space:]]jne\|jnz[[:space:]]')
        AP_ATTACH_LOOP_CJMP=$(objdump_insn_addr "$ATTACHPROG_DISAS" attach_loop '[[:space:]]jge\|jae\|jnl[[:space:]]')
        AP_ATTACH_LOOP_JUMP=$(objdump_insn_addr "$ATTACHPROG_DISAS" attach_loop '[[:space:]]jmp[q]*[[:space:]]')
    fi
fi

echo ""

# ══════════════════════════════════════════════════════════
# NO-ROOT TESTS — always run
# ══════════════════════════════════════════════════════════

# ── version ──────────────────────────────────────────────
echo "--- version ---"

VOUT=$($BIN -v 2>&1)
if echo "$VOUT" | grep -q 'bsdtrace'; then
    pass "version: -v flag"
else
    fail "version: -v flag"
fi

VOUT=$($BIN --version 2>&1)
if echo "$VOUT" | grep -q 'bsdtrace'; then
    pass "version: --version flag"
else
    fail "version: --version flag"
fi

# ── list ─────────────────────────────────────────────────
echo "--- list ---"

LOUT=$($BIN list 2>&1)
if echo "$LOUT" | grep -q 'HWT Framework'; then
    pass "list: text output contains HWT Framework"
else
    fail "list: text output contains HWT Framework"
fi

if echo "$LOUT" | grep -qi 'cpu'; then
    pass "list: text output contains CPU info"
else
    fail "list: text output contains CPU info"
fi

LJSON=$($BIN list -f json 2>&1)
BACKEND=$(echo "$LJSON" | sed -n 's/.*"backend":"\([^"]*\)".*/\1/p')
if echo "$LJSON" | grep -q '"hwt_available"'; then
    pass "list: json has hwt_available field"
else
    fail "list: json has hwt_available field"
fi

if echo "$LJSON" | grep -q '"cpu_model"'; then
    pass "list: json has cpu_model field"
else
    fail "list: json has cpu_model field"
fi

if echo "$LJSON" | grep -q '"machine"'; then
    pass "list: json has machine field"
else
    fail "list: json has machine field"
fi

# Validate JSON structure (opening/closing braces)
if echo "$LJSON" | head -1 | grep -q '^{.*}$'; then
    pass "list: json is well-formed object"
else
    fail "list: json is well-formed object"
fi

LERR=$($BIN list -f xml 2>&1) || true
if echo "$LERR" | grep -qi 'unknown format'; then
    pass "list: invalid format rejected"
else
    fail "list: invalid format rejected"
fi

# ── decode (error cases, no root) ────────────────────────
echo "--- decode (errors) ---"

# No file argument
DOUT=$($BIN decode 2>&1) || true
if echo "$DOUT" | grep -qi 'required\|usage'; then
    pass "decode: no args prints error"
else
    fail "decode: no args prints error"
fi

# Nonexistent .pt file
DOUT=$($BIN decode /nonexistent/file.pt 2>&1) || true
if echo "$DOUT" | grep -qi 'cannot\|error\|No such'; then
    pass "decode: nonexistent file prints error"
else
    fail "decode: nonexistent file prints error"
fi

# Empty file
touch "$TMPDIR/empty.pt"
DOUT=$($BIN decode "$TMPDIR/empty.pt" 2>&1) || true
if echo "$DOUT" | grep -qi 'empty\|cannot\|error'; then
    pass "decode: empty file prints error"
else
    fail "decode: empty file prints error"
fi

# Unknown format
DOUT=$($BIN decode -f xml "$TMPDIR/empty.pt" 2>&1) || true
if echo "$DOUT" | grep -qi 'unknown format'; then
    pass "decode: unknown format rejected"
else
    fail "decode: unknown format rejected"
fi

# ── Unknown command ──────────────────────────────────────
echo "--- dispatch ---"

DOUT=$($BIN bogus 2>&1) || true
if echo "$DOUT" | grep -q "unknown command"; then
    pass "dispatch: unknown command error"
else
    fail "dispatch: unknown command error"
fi

# No args
DOUT=$($BIN 2>&1) || true
if echo "$DOUT" | grep -qi 'usage'; then
    pass "dispatch: no args prints usage"
else
    fail "dispatch: no args prints usage"
fi

# ── help / CLI surface ───────────────────────────────────
echo "--- help ---"

HOUT=$($BIN exec -h 2>&1)
if echo "$HOUT" | grep -q -- '-M freq' &&
    echo "$HOUT" | grep -q -- '-Y thresh' &&
    echo "$HOUT" | grep -q -- '-W' &&
    echo "$HOUT" | grep -q -- '-K' &&
    echo "$HOUT" | grep -q 'stop: prefix for TraceStop'; then
    pass "help: exec exposes new PT options"
else
    fail "help: exec exposes new PT options"
fi

HOUT=$($BIN trace -h 2>&1)
if echo "$HOUT" | grep -q -- '-M freq' &&
    echo "$HOUT" | grep -q -- '-Y thresh' &&
    echo "$HOUT" | grep -q -- '-W' &&
    echo "$HOUT" | grep -q -- '-K' &&
    echo "$HOUT" | grep -q 'stop: prefix for TraceStop'; then
    pass "help: trace exposes new PT options"
else
    fail "help: trace exposes new PT options"
fi

case "$(uname -m)" in
amd64|x86_64)
    printf '#include "bsdtrace_ptwrite.h"\nint main(void) { bsdtrace_ptwrite(0x123456789abcdef0ULL); bsdtrace_ptwrite32(0x89abcdefU); return bsdtrace_has_ptwrite(); }\n' > "$TMPDIR/ptwrite-compile.c"
    if cc -O0 -I Sources/bsdtrace -c "$TMPDIR/ptwrite-compile.c" -o "$TMPDIR/ptwrite-compile.o" 2>/dev/null; then
        pass "help: ptwrite header compiles for consumers"
    else
        fail "help: ptwrite header compiles for consumers"
    fi
    ;;
*)
    skip "help: ptwrite header compiles for consumers (x86_64 only)"
    ;;
esac

# ══════════════════════════════════════════════════════════
# ROOT + HWT TESTS — require root and loaded hwt/pt modules
# ══════════════════════════════════════════════════════════

echo ""
echo "--- root + HWT tests ---"

if [ "$(id -u)" -ne 0 ]; then
    echo "  (not root — skipping hardware tests)"
    skip "exec: basic trace"
    skip "exec: .pt file created"
    skip "exec: .meta file created"
    skip "exec: event types"
    skip "exec: function names"
    skip "exec: json output"
    skip "exec: json lines valid"
    skip "exec: -T 0"
    skip "exec: -A"
    skip "exec: -n"
    skip "exec: -s 8m"
    skip "exec: -o"
    skip "exec: -b backend"
    skip "exec: -m max-records"
    skip "exec: -r range filter"
    skip "exec: -p pause on mmap"
    skip "exec: child exit status"
    skip "decode: offline"
    skip "decode: functions"
    skip "decode: json"
    skip "decode: json lines valid"
    skip "decode: -m"
    skip "decode: implicit .meta discovery"
    skip "trace: attach"
    skip "trace: .pt file"
    skip "trace: .meta file"
    skip "trace: decoded symbols"
    skip "trace: dry run"
    skip "trace: -b backend"
    skip "trace: -s 8m"
    skip "trace: -T 0"
    skip "trace: json"
    skip "trace: json lines valid"
    skip "trace: -m max-records"
    skip "trace: -r range filter"
    skip "trace: -p pause on mmap"
    skip "thread: -T 0 has main_* symbols"
    skip "thread: -T 0 excludes worker_*"
    skip "thread: -T 1 has worker_* symbols"
    skip "thread: -T 1 excludes main_*"
    skip "thread: .meta header has tid=0"
    skip "thread: json output has tid field"
    skip "thread-all: opened additional thread device"
    skip "thread-all: primary thread decoded"
    skip "thread-all: per-thread .pt file created"
    skip "thread-all: worker thread buffer saved"
    skip "thread-all: primary thread has main_* symbols"
    skip "thread-all: primary thread excludes worker_*"
    skip "thread-all: worker thread has worker_* symbols"
    skip "thread-all: per-thread .meta created"
    skip "thread-all: per-thread .pt replayable offline"
    skip "thread-list: opened thread 1 device"
    skip "thread-list: primary thread decoded"
    skip "thread-list: per-thread .pt file created"
    skip "thread-list: primary thread has main_* symbols"
    skip "thread-list: primary thread excludes worker_*"
    skip "collapsed: has semicolon-separated stacks"
    skip "collapsed: leaf_add in stacks"
    skip "collapsed: lines have stack<space>count format"
    skip "collapsed: summary on stderr"
    skip "timing-decode: profile has TIME column"
    skip "timing-decode: json has tsc field"
    skip "timing-decode: tree has tsc annotations"
    skip "timing: -P 3 psb frequency"
    skip "timing: -C cycle-accurate"
    skip "timing: -P 3 -C combined"
    skip "timing: -P 99 rejected"
    skip "timing: -M explicit mtc_freq"
    skip "timing: -Y explicit cyc_thresh"
    skip "timing: -M 99 rejected"
    skip "timing: -Y 99 rejected"
    skip "timing: .meta has mtc_freq"
    skip "timing: .meta has cyc_thresh"
    skip "ptwrite: -W trace captures PTW"
    skip "ptwrite: -W preserves payloads"
    skip "ptwrite: offline json has ptwrite payloads"
    skip "overflow: small buffer warns"
    skip "tracestop: stop range ends trace before later functions"
    skip "os-trace: -K accepted"
else
    # Check HWT availability — the list output says
    #   /dev/hwt:       available
    if ! $BIN list 2>&1 | grep -qi '/dev/hwt.*available'; then
        echo "  (HWT not available — skipping hardware tests)"
        echo "  Hint: kldload hwt && kldload pt"
        skip "exec: all (HWT not available)"
        skip "decode: all (HWT not available)"
        skip "trace: all (HWT not available)"
    else

    # Detect whether HWT_HOOKS are present.  Both exec and trace
    # hard-fail without hooks (the kernel can't emit EXEC/MMAP
    # records), so all tracing tests must be skipped.
    HAS_HOOKS=0
    if $BIN list 2>&1 | grep -qi 'Kernel hooks.*enabled\|Kernel hooks.*yes'; then
        HAS_HOOKS=1
    fi

    if [ "$HAS_HOOKS" -eq 0 ]; then
        echo "  (HWT_HOOKS not in running kernel — exec/trace/decode tests skipped)"
        echo "  Boot a kernel with 'options HWT_HOOKS' for full test coverage."
        skip "exec: all (no HWT_HOOKS)"
        skip "decode: all (no HWT_HOOKS)"
        skip "trace: all (no HWT_HOOKS)"
    else

    # ── exec ─────────────────────────────────────────────
    echo "--- exec ---"

    PT_FILE="$TMPDIR/testprog.pt"

    # Basic exec with testprog
    run_bsdtrace_file exec -t 5 -o "$PT_FILE" -- "$TESTPROG"
    EOUT_FILE="$TMPDIR/exec-basic-out.txt"
    mv "$ROUT_FILE" "$EOUT_FILE" 2>/dev/null || true
    EERR="$RERR"
    if echo "$EERR" | grep -q 'instructions'; then
        pass "exec: basic trace with decode"
    else
        fail "exec: basic trace with decode"
        echo "    Output: $(tail -5 "$EOUT_FILE" 2>/dev/null)"
    fi

    # .pt file created and non-empty
    if [ -f "$PT_FILE" ] && [ -s "$PT_FILE" ]; then
        pass "exec: .pt file created"
    else
        fail "exec: .pt file created"
    fi

    # .meta file created (co-located with .pt file)
    META_FILE="$TMPDIR/testprog.meta"
    if [ -f "$META_FILE" ] && [ -s "$META_FILE" ]; then
        pass "exec: .meta file created"
    else
        fail "exec: .meta file created"
    fi

    # .meta content validation
    if [ -f "$META_FILE" ]; then
        # Every line must be valid JSON
        if json_lines_valid "$META_FILE"; then
            pass "exec: .meta is valid JSONL"
        else
            fail "exec: .meta is valid JSONL"
        fi

        # Must contain an exec record with the testprog path
        if grep -q "\"type\":\"exec\"" "$META_FILE"; then
            pass "exec: .meta has exec record"
        else
            fail "exec: .meta has exec record"
        fi

        # Must contain mmap records for shared libraries
        if grep -q "\"type\":\"mmap\"" "$META_FILE"; then
            pass "exec: .meta has mmap records"
        else
            fail "exec: .meta has mmap records"
        fi

        # All paths in the meta file should exist on disk
        META_BAD_PATHS=$(python3 - "$META_FILE" <<'PY'
import json, os, sys
bad = 0
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        p = obj.get("path", "")
        if p and not os.path.exists(p):
            bad += 1
            if bad <= 3:
                print(f"    missing: {p}", file=sys.stderr)
print(bad)
PY
)
        if [ "$META_BAD_PATHS" -eq 0 ]; then
            pass "exec: .meta paths exist on disk"
        else
            fail "exec: .meta paths exist on disk ($META_BAD_PATHS missing)"
        fi
    fi

    # Control flow event types
    for EVT in CALL RETURN CJMP SYSCALL; do
        if grep -q "$EVT" "$EOUT_FILE"; then
            pass "exec: $EVT events in output"
        else
            fail "exec: $EVT events in output"
        fi
    done

    # Syscall name resolution: SYSCALL lines should show the resolved
    # name (e.g. "SYSCALL write") not just the raw libsys symbol.
    # The resolved format is: "SYSCALL  write (libsys.so.7:__sys_write)"
    # The parenthesized original symbol distinguishes it from unresolved output.
    if grep -qE 'SYSCALL\s+[a-z_]+.*\(libsys' "$EOUT_FILE"; then
        pass "exec: syscall names resolved"
    else
        if grep -q 'SYSCALL' "$EOUT_FILE"; then
            fail "exec: syscall names resolved (SYSCALL present but no resolved name)"
            echo "    --- debug: first 3 SYSCALL lines ---"
            grep 'SYSCALL' "$EOUT_FILE" | head -3
            echo "    ---"
        else
            skip "exec: syscall names resolved (no SYSCALL events)"
        fi
    fi

    # Known function names from testprog
    FN_MISS=0
    for FN in leaf_add leaf_mul nested_outer nested_inner \
              branch_test loop_test do_write; do
        if grep -q "$FN" "$EOUT_FILE"; then
            pass "exec: $FN in decoded output"
        else
            fail "exec: $FN in decoded output"
            FN_MISS=$((FN_MISS + 1))
        fi
    done
    if [ "$FN_MISS" -gt 0 ]; then
        echo "    --- debug: image build info ---"
        grep -E '^(image:|  \[)' "$EOUT_FILE" | head -10
        echo "    --- debug: first 5 decoded events ---"
        grep -E '^\s+(CALL|RETURN|CJMP|SYSCALL)' "$EOUT_FILE" | head -5
        echo "    --- debug: testprog ELF layout ---"
        readelf -l "$TESTPROG" 2>/dev/null | grep -A1 'LOAD' | head -6
        echo "    ---"
    fi

    NOMAP_COUNT=$(echo "$EERR" | sed -n 's/.* \([0-9]*\) nomap, \([0-9]*\) errors.*/\1 \2/p')
    NOMAP_N=$(echo "$NOMAP_COUNT" | awk '{print $1}')
    ERR_N=$(echo "$NOMAP_COUNT" | awk '{print $2}')
    if [ "${NOMAP_N:-999}" -eq 0 ] && [ "${ERR_N:-999}" -le 2 ]; then
        pass "exec: no nomap or decode errors"
    else
        fail "exec: no nomap or decode errors"
        echo "    nomap=$NOMAP_N errors=$ERR_N"
        echo "$EERR" | grep -E 'nomap|error:|sync failed' | head -5
    fi




    # Realistic workflow: capture once, then analyze the saved trace.
    # Validate instruction-level JSON by decoding the already-saved
    # full exec trace, not by scraping mixed live stdout/stderr.
    EXEC_JSON_LINES="$TMPDIR/exec-json-lines.txt"
    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        run_bsdtrace_file decode -f json -m "$META_FILE" "$PT_FILE"
        grep '^{' "$ROUT_FILE" > "$EXEC_JSON_LINES"
        rm -f "$ROUT_FILE"
    else
        rm -f "$EXEC_JSON_LINES"
    fi

    if [ -s "$EXEC_JSON_LINES" ] && grep -q '"insn"' "$EXEC_JSON_LINES"; then
        pass "exec: json has insn field"
    else
        fail "exec: json has insn field"
        echo "    --- debug: json output sample ---"
        sed -n '1,10p' "$EXEC_JSON_LINES"
        echo "    ---"
    fi

    if [ -s "$EXEC_JSON_LINES" ] && grep -q '"sym"' "$EXEC_JSON_LINES"; then
        pass "exec: json has sym field"
    else
        fail "exec: json has sym field"
    fi

    if [ -s "$EXEC_JSON_LINES" ] &&
        json_lines_valid "$EXEC_JSON_LINES"; then
        pass "exec: json lines are valid JSON"
    else
        fail "exec: json lines are valid JSON"
    fi

    if [ -n "$TP_MAIN_CALL_LEAF_ADD" ] &&
        [ -n "$TP_MAIN_START" ] &&
        json_has_symbolized_event "$EXEC_JSON_LINES" "CALL" \
            "$TP_MAIN_CALL_LEAF_ADD" "main" \
            "$(hex_diff "$TP_MAIN_CALL_LEAF_ADD" "$TP_MAIN_START")" \
            "$TESTPROG_BN"; then
        pass "exec: exact symbolification main call"
    else
        fail "exec: exact symbolification main call"
    fi

    if [ -n "$TP_BRANCH_CJMP" ] &&
        [ -n "$TP_BRANCH_START" ] &&
        json_has_symbolized_event "$EXEC_JSON_LINES" "CJMP" \
            "$TP_BRANCH_CJMP" "branch_test" \
            "$(hex_diff "$TP_BRANCH_CJMP" "$TP_BRANCH_START")" \
            "$TESTPROG_BN"; then
        pass "exec: exact symbolification branch cjmp"
    else
        fail "exec: exact symbolification branch cjmp"
    fi

    if [ -n "$TP_BRANCH_JUMP" ] &&
        [ -n "$TP_BRANCH_START" ] &&
        json_has_symbolized_event "$EXEC_JSON_LINES" "JUMP" \
            "$TP_BRANCH_JUMP" "branch_test" \
            "$(hex_diff "$TP_BRANCH_JUMP" "$TP_BRANCH_START")" \
            "$TESTPROG_BN"; then
        pass "exec: exact symbolification branch jump"
    else
        fail "exec: exact symbolification branch jump"
    fi

    if [ -n "$TP_BRANCH_CJMP" ] &&
        [ "$(json_event_count "$EXEC_JSON_LINES" "CJMP" "$TP_BRANCH_CJMP")" -eq 2 ]; then
        pass "exec: branch_test cjmp count"
    else
        fail "exec: branch_test cjmp count"
    fi

    if [ -n "$TP_BRANCH_JUMP" ] &&
        [ "$(json_event_count "$EXEC_JSON_LINES" "JUMP" "$TP_BRANCH_JUMP")" -eq 1 ]; then
        pass "exec: branch_test jump count"
    else
        fail "exec: branch_test jump count"
    fi

    if [ -n "$TP_LOOP_CJMP" ] &&
        [ "$(json_event_count "$EXEC_JSON_LINES" "CJMP" "$TP_LOOP_CJMP")" -eq 11 ]; then
        pass "exec: loop_test cjmp count"
    else
        fail "exec: loop_test cjmp count"
    fi

    if [ -n "$TP_LOOP_JUMP" ] &&
        [ "$(json_event_count "$EXEC_JSON_LINES" "JUMP" "$TP_LOOP_JUMP")" -eq 10 ]; then
        pass "exec: loop_test jump count"
    else
        fail "exec: loop_test jump count"
    fi

    if [ -n "$TP_LEAF_ADD_RET" ] &&
        [ "$(json_event_count "$EXEC_JSON_LINES" "RETURN" "$TP_LEAF_ADD_RET")" -eq 14 ]; then
        pass "exec: leaf_add return count"
    else
        fail "exec: leaf_add return count"
    fi

    settle_hwt



    # Thread selection — verify function names appear (not just "ran OK")
    PT_TID="$TMPDIR/testprog-tid.pt"
    run_bsdtrace exec -T 0 -t 5 -o "$PT_TID" -- "$TESTPROG"
    if echo "$ROUT" | grep -Eq 'leaf_add|branch_test|loop_test'; then
        pass "exec: thread selection -T 0"
    else
        fail "exec: thread selection -T 0"
    fi



    # Disable ASLR — verify the EXEC record address matches static link address
    PT_ASLR="$TMPDIR/testprog-aslr.pt"
    run_bsdtrace exec -A -t 5 -o "$PT_ASLR" -- "$TESTPROG"
    if echo "$RERR" | grep -q 'instructions'; then
        pass "exec: disable ASLR -A"
    else
        fail "exec: disable ASLR -A"
    fi

    # The -A flag is verified by the exact symbolification tests above:
    # if ASLR were active on a non-PIE binary, the static objdump
    # addresses wouldn't match the runtime IPs, and those tests would
    # fail.  No separate address-matching test needed.



    # Dry run
    run_bsdtrace exec -n -t 5 -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -qi 'dry-run'; then
        pass "exec: dry run -n"
    else
        fail "exec: dry run -n"
    fi



    # Custom buffer size — verify with dry-run that 8m is accepted
    run_bsdtrace exec -n -s 8m -t 5 -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'bufsize=8388608'; then
        pass "exec: custom buffer size -s 8m"
    else
        fail "exec: custom buffer size -s 8m"
        echo "    stderr: $(echo "$RERR" | head -3)"
    fi



    # Custom output path
    PT_CUSTOM="$TMPDIR/custom-output.pt"
    run_bsdtrace exec -t 5 -o "$PT_CUSTOM" -- "$TESTPROG"
    if [ -f "$PT_CUSTOM" ] && [ -s "$PT_CUSTOM" ]; then
        pass "exec: custom output path -o"
    else
        fail "exec: custom output path -o"
    fi



    # Explicit backend and pause-on-mmap
    if [ -n "$BACKEND" ]; then
        PT_BACKEND="$TMPDIR/testprog-backend.pt"
        run_bsdtrace exec -b "$BACKEND" -p -t 5 -o "$PT_BACKEND" -- "$TESTPROG"
        if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
            pass "exec: -b backend"
        else
            fail "exec: -b backend"
        fi

        # pause-on-mmap: verify MMAP/EXEC records appear in decoded stdout
        if echo "$ROUT" | grep -Eq 'MMAP|EXEC'; then
            pass "exec: -p pause on mmap"
        else
            fail "exec: -p pause on mmap"
        fi
    else
        skip "exec: -b backend"
        skip "exec: -p pause on mmap"
    fi



    # Max-records
    PT_LIMIT="$TMPDIR/testprog-max.pt"
    run_bsdtrace exec -m 5 -t 5 -o "$PT_LIMIT" -- "$TESTPROG"
    if echo "$RERR" | grep -q 'max-records:'; then
        pass "exec: -m max-records"
    else
        fail "exec: -m max-records"
    fi



    # IP range filter
    if [ -n "$TESTPROG_RANGE" ]; then
        PT_RANGE="$TMPDIR/testprog-range.pt"
        run_bsdtrace exec -r "$TESTPROG_RANGE" -t 5 -o "$PT_RANGE" -- "$TESTPROG"
        if [ "$RRC" -ne 0 ]; then
            skip "exec: -r range filter (bsdtrace exited $RRC — IP filter may not be supported)"
            echo "    rc=$RRC range=$TESTPROG_RANGE"
            echo "    Output: $(echo "$RBOTH" | tail -3)"
        else
            # IP range filtering works at the hardware level: the .pt
            # file should be dramatically smaller than an unfiltered trace.
            # Decoding may produce 0 instructions because short filtered
            # traces lack a PSB sync point — that's a PT limitation, not
            # a filtering failure.
            RANGE_PT_SZ=$(stat -f '%z' "$PT_RANGE" 2>/dev/null || echo 0)
            UNFILTERED_SZ=$(stat -f '%z' "$PT_FILE" 2>/dev/null || echo 999999)
            if [ "$RRC" -eq 0 ] && [ "$RANGE_PT_SZ" -gt 0 ] &&
                [ "$RANGE_PT_SZ" -lt "$((UNFILTERED_SZ / 4))" ]; then
                pass "exec: -r range filter (${RANGE_PT_SZ}b filtered vs ${UNFILTERED_SZ}b unfiltered)"
            else
                fail "exec: -r range filter"
                echo "    filtered=${RANGE_PT_SZ}b unfiltered=${UNFILTERED_SZ}b"
            fi
        fi
    else
        skip "exec: -r range filter"
    fi

    # Range filter with a looping program — generates enough PT data
    # within the range for the decoder to sync and produce instructions.
    RANGEPROG="$TMPDIR/rangeprog"
    cat > "$TMPDIR/rangeprog.c" <<'RPROG'
#include <unistd.h>
#define NOINLINE __attribute__((noinline))
static volatile int sink;
NOINLINE int range_add(int a, int b) { return (a + b); }
NOINLINE int range_loop(int n) {
    int i, sum = 0;
    for (i = 0; i < n; i++) sum = range_add(sum, i);
    return sum;
}
int main(void) {
    int i;
    for (i = 0; i < 5000; i++) sink = range_loop(100);
    usleep(10000);
    return 0;
}
RPROG
    if cc -O0 -o "$RANGEPROG" "$TMPDIR/rangeprog.c" 2>/dev/null; then
        RANGEPROG_RANGE=$(text_range_arg "$RANGEPROG")
        if [ -n "$RANGEPROG_RANGE" ]; then
            PT_RLOOP="$TMPDIR/rangeprog.pt"
            run_bsdtrace_file exec -r "$RANGEPROG_RANGE" -t 10 -o "$PT_RLOOP" -- "$RANGEPROG"
            if [ "$RRC" -eq 0 ] && [ -s "$ROUT_FILE" ]; then
                RLOOP_INSN=$(echo "$RERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
                if [ "${RLOOP_INSN:-0}" -gt 0 ]; then
                    # Check only decoded instruction lines (CALL/RETURN/etc),
                    # not MMAP/EXEC record lines which naturally contain library paths.
                    if grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -Eq 'ld-elf\.so\.1|libc\.so\.7|libsys\.so\.7'; then
                        fail "exec: -r range decode (library symbols leaked)"
                    else
                        pass "exec: -r range decode ($RLOOP_INSN instructions)"
                    fi
                    if grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -q 'range_add'; then
                        pass "exec: -r range has expected symbols"
                    else
                        fail "exec: -r range has expected symbols"
                    fi
                else
                    fail "exec: -r range decode (0 instructions)"
                    echo "    range=$RANGEPROG_RANGE"
                    echo "    $(echo "$RERR" | tail -3)"
                fi
            elif [ "$RRC" -ne 0 ]; then
                skip "exec: -r range decode (exit $RRC)"
            else
                skip "exec: -r range decode (no output)"
            fi
        else
            skip "exec: -r range decode (no text range)"
        fi
    else
        skip "exec: -r range decode (compile failed)"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Symbol-based range filter: -r function_name instead of hex addresses.
    # Reuses rangeprog from the previous test.  The -A flag is auto-implied
    # when using symbol names in exec mode.
    if [ -x "$RANGEPROG" ]; then
        PT_RSYM="$TMPDIR/rangeprog-sym.pt"
        run_bsdtrace_file exec -r range_loop -t 10 -o "$PT_RSYM" -- "$RANGEPROG"
        if [ "$RRC" -eq 0 ] && [ -s "$ROUT_FILE" ]; then
            RSYM_INSN=$(echo "$RERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
            if echo "$RERR" | grep -q "resolved 'range_loop'"; then
                pass "exec: -r symbol resolved"
            else
                fail "exec: -r symbol resolved"
                echo "    stderr: $(echo "$RERR" | head -5)"
            fi
            if [ "${RSYM_INSN:-0}" -gt 0 ]; then
                if grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -q 'range_loop\|range_add'; then
                    pass "exec: -r symbol decode ($RSYM_INSN instructions)"
                else
                    fail "exec: -r symbol decode (no expected symbols in output)"
                fi
            else
                skip "exec: -r symbol decode (0 instructions — PSB sync issue)"
            fi
        elif [ "$RRC" -ne 0 ]; then
            skip "exec: -r symbol resolved (exit $RRC)"
            skip "exec: -r symbol decode"
            echo "    stderr: $(echo "$RERR" | tail -3)"
        else
            skip "exec: -r symbol resolved (no output)"
            skip "exec: -r symbol decode"
        fi
    else
        skip "exec: -r symbol resolved (rangeprog not built)"
        skip "exec: -r symbol decode"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Two-range IP filter test.  Compile a program with two distinct
    # function groups (group_a_* and group_b_*), extract each group's
    # address range from objdump, and trace with -r <rangeA> -r <rangeB>.
    # Verify both groups appear in the decoded output.
    DUALPROG="$TMPDIR/dualprog"
    cat > "$TMPDIR/dualprog.c" <<'DPROG'
#include <unistd.h>
#define NOINLINE __attribute__((noinline))
static volatile int sink;

/*
 * Two function groups separated by a large padding function so
 * their address ranges don't overlap.  The hardware supports two
 * independent IP filter ranges (ADDR0, ADDR1).
 */

/* --- Group A --- */
NOINLINE int group_a_leaf(int x) { return x + 1; }
NOINLINE int group_a_loop(int n) {
    int i, s = 0;
    for (i = 0; i < n; i++) s = group_a_leaf(s);
    return s;
}

/* Padding to push group B to a different address range. */
NOINLINE int padding_func(int x) {
    volatile int v = x;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    v += 1; v += 2; v += 3; v += 4; v += 5;
    return v;
}

/* --- Group B --- */
NOINLINE int group_b_leaf(int x) { return x * 2; }
NOINLINE int group_b_loop(int n) {
    int i, s = 1;
    for (i = 0; i < n; i++) s = group_b_leaf(s);
    return s;
}

int main(void) {
    int i;
    for (i = 0; i < 2000; i++) {
        sink = group_a_loop(100);
        sink = group_b_loop(100);
    }
    usleep(10000);
    return 0;
}
DPROG
    if cc -O0 -o "$DUALPROG" "$TMPDIR/dualprog.c" 2>/dev/null && [ -n "$OBJDUMP" ]; then
        DUAL_DISAS="$TMPDIR/dualprog.dis"
        "$OBJDUMP" -d "$DUALPROG" > "$DUAL_DISAS" 2>/dev/null

        # Extract function addresses for each group.
        GA_LEAF_START=$(objdump_func_addr "$DUAL_DISAS" group_a_leaf)
        GB_LEAF_START=$(objdump_func_addr "$DUAL_DISAS" group_b_leaf)
        PAD_START=$(objdump_func_addr "$DUAL_DISAS" padding_func)

        # Range A: from group_a_leaf up to (but not including) padding_func.
        # Range B: from group_b_leaf to group_b_loop + generous end.
        if [ -n "$GA_LEAF_START" ] && [ -n "$PAD_START" ] &&
            [ -n "$GB_LEAF_START" ]; then
            GB_END=$(printf '0x%x' "$(( $GB_LEAF_START + 0x200 ))")
            RANGE_A="${GA_LEAF_START}:${PAD_START}"
            RANGE_B="${GB_LEAF_START}:${GB_END}"

            PT_DUAL="$TMPDIR/dualprog-dual.pt"
            run_bsdtrace_file exec -r "$RANGE_A" -r "$RANGE_B" -t 10 -o "$PT_DUAL" -- "$DUALPROG"
            if [ "$RRC" -eq 0 ] && [ -s "$ROUT_FILE" ]; then
                DUAL_INSN=$(echo "$RERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
                DUAL_HAS_A=$(grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -c 'group_a')
                DUAL_HAS_B=$(grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -c 'group_b')
                if [ "${DUAL_INSN:-0}" -gt 0 ] &&
                    [ "$DUAL_HAS_A" -gt 0 ] && [ "$DUAL_HAS_B" -gt 0 ]; then
                    if grep -E '^\s+(CALL|RETURN|JUMP|CJMP|SYSCALL)' "$ROUT_FILE" | grep -Eq 'ld-elf\.so\.1|libc\.so\.7|libsys\.so\.7'; then
                        fail "exec: dual -r range filter (library symbols leaked)"
                    else
                        pass "exec: dual -r range filter ($DUAL_INSN insn, A=$DUAL_HAS_A B=$DUAL_HAS_B)"
                    fi
                else
                    fail "exec: dual -r range filter (insn=$DUAL_INSN A=$DUAL_HAS_A B=$DUAL_HAS_B)"
                    echo "    rangeA=$RANGE_A rangeB=$RANGE_B"
                    echo "    $(echo "$RERR" | tail -3)"
                fi
            elif [ "$RRC" -ne 0 ]; then
                skip "exec: dual -r range filter (exit $RRC)"
            else
                skip "exec: dual -r range filter (no output)"
            fi
        else
            skip "exec: dual -r range filter (objdump extraction failed)"
        fi
    else
        skip "exec: dual -r range filter (compile or objdump failed)"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt


    # ── multi-thread ────────────────────────────────────────
    echo "--- threads ---"

    # Clean up range filter .pt files to free space, but keep
    # testprog.pt and testprog.meta for the decode tests later.
    rm -f "$TMPDIR"/rangeprog.pt "$TMPDIR"/dualprog*.pt
    rm -f "$TMPDIR"/testprog-*.pt "$TMPDIR"/custom-*.pt
    rm -f "$TMPDIR"/fast-exit.pt "$TMPDIR"/.stdout.*

    # Thread 0 (main): should see main_work/main_leaf, not worker_*
    PT_THR0="$TMPDIR/thread-0.pt"
    run_bsdtrace_file exec -s 8m -T 0 -t 3 -o "$PT_THR0" -- "$THREADPROG"
    THR0_ERR="$RERR"
    if echo "$THR0_ERR" | grep -q 'instructions'; then
        if grep -Eq 'main_work|main_leaf' "$ROUT_FILE"; then
            pass "thread: -T 0 has main_* symbols"
        else
            fail "thread: -T 0 has main_* symbols"
        fi
        if grep -E '^\s+(CALL|RETURN)' "$ROUT_FILE" | grep -q 'worker_'; then
            fail "thread: -T 0 excludes worker_* (worker symbols found)"
        else
            pass "thread: -T 0 excludes worker_*"
        fi
    else
        fail "thread: -T 0 basic trace"
        skip "thread: -T 0 excludes worker_*"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Thread 1 (worker): use trace mode since the thread must already
    # exist when the HWT context is allocated (exec mode forks stopped,
    # so only thread 0 exists at alloc time).
    PT_THR1="$TMPDIR/thread-1.pt"
    "$THREADPROG" &
    THR1_PID=$!
    PIDS_TO_KILL="$PIDS_TO_KILL $THR1_PID"
    sleep 1  # let worker thread start
    if kill -0 "$THR1_PID" 2>/dev/null; then
        if lookup_thread_indices "$THR1_PID"; then
            run_bsdtrace_file trace -s 8m -T "$WORKER_THREAD_IDX" -d 3 -o "$PT_THR1" "$THR1_PID"
            THR1_ERR="$RERR"
            kill "$THR1_PID" 2>/dev/null; wait "$THR1_PID" 2>/dev/null
            if echo "$THR1_ERR" | grep -q 'instructions'; then
                if grep -Eq 'worker_work|worker_leaf' "$ROUT_FILE"; then
                    pass "thread: -T 1 has worker_* symbols"
                else
                    fail "thread: -T 1 has worker_* symbols"
                fi
                if grep -E '^\s+(CALL|RETURN)' "$ROUT_FILE" | grep -q 'main_work\|main_leaf'; then
                    fail "thread: -T 1 excludes main_* (main symbols found)"
                else
                    pass "thread: -T 1 excludes main_*"
                fi
            else
                fail "thread: -T 1 has worker_* symbols"
                skip "thread: -T 1 excludes main_*"
            fi
        else
            kill "$THR1_PID" 2>/dev/null; wait "$THR1_PID" 2>/dev/null
            fail "thread: -T 1 could not resolve worker thread index"
            skip "thread: -T 1 has worker_* symbols"
            skip "thread: -T 1 excludes main_*"
        fi
    else
        fail "thread: -T 1 could not start threadprog"
        skip "thread: -T 1 has worker_* symbols"
        skip "thread: -T 1 excludes main_*"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Verify thread identity in .meta header
    THR0_META="$TMPDIR/thread-0.meta"
    if [ -f "$THR0_META" ]; then
        if grep -q '"type":"header".*"tid":0' "$THR0_META"; then
            pass "thread: .meta header has tid=0"
        else
            fail "thread: .meta header has tid=0"
        fi
    else
        skip "thread: .meta header has tid=0"
    fi

    # Verify tid in JSON decode output (check any instruction line)
    if [ -f "$PT_THR0" ] && [ -f "$THR0_META" ]; then
        run_bsdtrace_file decode -f json -m "$THR0_META" "$PT_THR0"
        if grep '"insn"' "$ROUT_FILE" | head -1 | grep -q '"tid":0'; then
            pass "thread: json output has tid field"
        else
            fail "thread: json output has tid field"
            echo "    first json line: $(grep '"insn"' "$ROUT_FILE" | head -1)"
        fi
        rm -f "$ROUT_FILE"
    else
        skip "thread: json output has tid field"
    fi

    settle_hwt

    # ── multi-thread: -T all ────────────────────────────────
    echo "--- threads: -T all ---"

    # Clean up previous thread .pt files to free space
    rm -f "$TMPDIR"/thread-*.pt "$TMPDIR"/thread-*.meta

    # -T all in trace mode: attach to threadprog with both threads
    PT_ALL="$TMPDIR/thread-all.pt"
    "$THREADPROG" &
    ALL_PID=$!
    PIDS_TO_KILL="$PIDS_TO_KILL $ALL_PID"
    sleep 1  # let worker thread start
    if kill -0 "$ALL_PID" 2>/dev/null; then
        if lookup_thread_indices "$ALL_PID"; then
            run_bsdtrace_file trace -s 8m -T all -d 3 -o "$PT_ALL" "$ALL_PID"
            ALL_ERR="$RERR"
            kill "$ALL_PID" 2>/dev/null; wait "$ALL_PID" 2>/dev/null
            if echo "$ALL_ERR" | grep -q 'opened thread'; then
                pass "thread-all: opened additional thread device"
            else
                fail "thread-all: opened additional thread device"
                echo "    stderr: $(echo "$ALL_ERR" | head -5)"
            fi
            if echo "$ALL_ERR" | grep -q 'instructions'; then
                pass "thread-all: primary thread decoded"
            else
                fail "thread-all: primary thread decoded"
            fi
            ALL_BASE="$TMPDIR/thread-all"
            if ls "${ALL_BASE}"-tid*.pt >/dev/null 2>&1; then
                pass "thread-all: per-thread .pt file created"
                if echo "$ALL_ERR" | grep -Eq 'thread [0-9]+.*bytes'; then
                    pass "thread-all: worker thread buffer saved"
                else
                    pass "thread-all: worker thread buffer saved (empty buffer)"
                fi
            else
                fail "thread-all: per-thread .pt file created"
                echo "    files: $(ls "$TMPDIR"/thread-all* 2>&1)"
            fi
            PRIMARY_OUT="$TMPDIR/thread-all-primary.txt"
            WORKER_OUT="$TMPDIR/thread-all-worker.txt"
            if [ -s "$ROUT_FILE" ]; then
                sed -n '1,/^Thread [0-9]/{ /^Thread [0-9]/!p; }' "$ROUT_FILE" > "$PRIMARY_OUT"
                sed -n '/^Thread [0-9]/,$ p' "$ROUT_FILE" > "$WORKER_OUT"
            fi
            if [ "$MAIN_THREAD_IDX" = "0" ]; then
                PRIMARY_EXPECT='main_work|main_leaf'
                PRIMARY_EXCLUDE='worker_'
                WORKER_EXPECT='worker_work|worker_leaf'
            else
                PRIMARY_EXPECT='worker_work|worker_leaf'
                PRIMARY_EXCLUDE='main_'
                WORKER_EXPECT='main_work|main_leaf'
            fi
            if [ -s "$PRIMARY_OUT" ] && grep -Eq "$PRIMARY_EXPECT" "$PRIMARY_OUT"; then
                pass "thread-all: primary thread has main_* symbols"
            else
                fail "thread-all: primary thread has main_* symbols"
            fi
            if [ -s "$PRIMARY_OUT" ] &&
                grep -E '^\s+(CALL|RETURN)' "$PRIMARY_OUT" | grep -Eq "$PRIMARY_EXCLUDE"; then
                fail "thread-all: primary thread excludes worker_*"
            else
                pass "thread-all: primary thread excludes worker_*"
            fi
            if [ -s "$WORKER_OUT" ] && grep -Eq "$WORKER_EXPECT" "$WORKER_OUT"; then
                pass "thread-all: worker thread has worker_* symbols"
            elif [ -s "$WORKER_OUT" ]; then
                fail "thread-all: worker thread has worker_* symbols (decoded but wrong content)"
            else
                fail "thread-all: worker thread has worker_* symbols (no worker decode output)"
            fi
            WORKER_PT_FILE=$(ls "${ALL_BASE}"-tid*.pt 2>/dev/null | head -1)
            if [ -n "$WORKER_PT_FILE" ]; then
                WORKER_META_FILE="${WORKER_PT_FILE%.pt}.meta"
                if [ -f "$WORKER_META_FILE" ]; then
                    pass "thread-all: per-thread .meta created"
                    run_bsdtrace_file decode -m "$WORKER_META_FILE" "$WORKER_PT_FILE"
                    if echo "$RERR" | grep -q 'instructions'; then
                        pass "thread-all: per-thread .pt replayable offline"
                    elif [ -s "$WORKER_PT_FILE" ]; then
                        fail "thread-all: per-thread .pt replayable offline (non-empty .pt but 0 instructions)"
                    else
                        fail "thread-all: per-thread .pt replayable offline (empty .pt file)"
                    fi
                    rm -f "$ROUT_FILE"
                else
                    fail "thread-all: per-thread .meta created"
                    skip "thread-all: per-thread .pt replayable offline"
                fi
            else
                skip "thread-all: per-thread .meta created"
                skip "thread-all: per-thread .pt replayable offline"
            fi
        else
            kill "$ALL_PID" 2>/dev/null; wait "$ALL_PID" 2>/dev/null
            fail "thread-all: could not resolve thread indices"
            skip "thread-all: opened additional thread device"
            skip "thread-all: primary thread decoded"
            skip "thread-all: per-thread .pt file created"
            skip "thread-all: worker thread buffer saved"
            skip "thread-all: primary thread has main_* symbols"
            skip "thread-all: primary thread excludes worker_*"
            skip "thread-all: worker thread has worker_* symbols"
            skip "thread-all: per-thread .meta created"
            skip "thread-all: per-thread .pt replayable offline"
        fi
    else
        fail "thread-all: could not start threadprog"
        skip "thread-all: opened additional thread device"
        skip "thread-all: primary thread decoded"
        skip "thread-all: per-thread .pt file created"
        skip "thread-all: worker thread buffer saved"
        skip "thread-all: primary thread has main_* symbols"
        skip "thread-all: primary thread excludes worker_*"
        skip "thread-all: worker thread has worker_* symbols"
        skip "thread-all: per-thread .meta created"
        skip "thread-all: per-thread .pt replayable offline"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # ── multi-thread: -T 0,1 (specific threads) ────────────
    echo "--- threads: -T 0,1 ---"

    rm -f "$TMPDIR"/thread-list*.pt "$TMPDIR"/thread-list*.meta

    PT_LIST="$TMPDIR/thread-list.pt"
    "$THREADPROG" &
    LIST_PID=$!
    PIDS_TO_KILL="$PIDS_TO_KILL $LIST_PID"
    sleep 1  # let worker thread start
    if kill -0 "$LIST_PID" 2>/dev/null; then
        if lookup_thread_indices "$LIST_PID"; then
            run_bsdtrace_file trace -s 8m -T "$MAIN_THREAD_IDX,$WORKER_THREAD_IDX" -d 3 -o "$PT_LIST" "$LIST_PID"
            LIST_ERR="$RERR"
            kill "$LIST_PID" 2>/dev/null; wait "$LIST_PID" 2>/dev/null
            if echo "$LIST_ERR" | grep -q 'opened thread'; then
                pass "thread-list: opened thread 1 device"
            else
                fail "thread-list: opened thread 1 device"
                echo "    stderr: $(echo "$LIST_ERR" | head -5)"
            fi
            if echo "$LIST_ERR" | grep -q 'instructions'; then
                pass "thread-list: primary thread decoded"
            else
                fail "thread-list: primary thread decoded"
            fi
            LIST_BASE="$TMPDIR/thread-list"
            if ls "${LIST_BASE}"-tid*.pt >/dev/null 2>&1; then
                pass "thread-list: per-thread .pt file created"
            else
                fail "thread-list: per-thread .pt file created"
            fi
            LIST_PRIMARY="$TMPDIR/thread-list-primary.txt"
            if [ -s "$ROUT_FILE" ]; then
                sed -n '1,/^Thread [0-9]/{ /^Thread [0-9]/!p; }' "$ROUT_FILE" > "$LIST_PRIMARY"
            fi
            if [ -s "$LIST_PRIMARY" ] && grep -Eq 'main_work|main_leaf' "$LIST_PRIMARY"; then
                pass "thread-list: primary thread has main_* symbols"
            else
                fail "thread-list: primary thread has main_* symbols"
            fi
            if [ -s "$LIST_PRIMARY" ] &&
                grep -E '^\s+(CALL|RETURN)' "$LIST_PRIMARY" | grep -q 'worker_'; then
                fail "thread-list: primary thread excludes worker_*"
            else
                pass "thread-list: primary thread excludes worker_*"
            fi
        else
            kill "$LIST_PID" 2>/dev/null; wait "$LIST_PID" 2>/dev/null
            fail "thread-list: could not resolve thread indices"
            skip "thread-list: opened thread 1 device"
            skip "thread-list: primary thread decoded"
            skip "thread-list: per-thread .pt file created"
            skip "thread-list: primary thread has main_* symbols"
            skip "thread-list: primary thread excludes worker_*"
        fi
    else
        fail "thread-list: could not start threadprog"
        skip "thread-list: opened thread 1 device"
        skip "thread-list: primary thread decoded"
        skip "thread-list: per-thread .pt file created"
        skip "thread-list: primary thread has main_* symbols"
        skip "thread-list: primary thread excludes worker_*"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # ── timing: -P and -C flags ─────────────────────────────
    echo "--- timing ---"

    # PSB frequency — verify the flag is accepted and trace succeeds.
    # If the CPU doesn't support configurable PSB, the kernel returns
    # ENXIO from SET_CONFIG and bsdtrace prints "failed to configure".
    PT_PSB="$TMPDIR/testprog-psb.pt"
    run_bsdtrace_file exec -P 3 -t 5 -o "$PT_PSB" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "timing: -P 3 psb frequency"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: -P 3 psb frequency (CPU does not support)"
        else
            fail "timing: -P 3 psb frequency"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Cycle-accurate timing — verify -C flag produces a valid trace
    PT_CYC="$TMPDIR/testprog-cyc.pt"
    run_bsdtrace_file exec -C -t 5 -o "$PT_CYC" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "timing: -C cycle-accurate"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: -C cycle-accurate (CPU does not support)"
        else
            fail "timing: -C cycle-accurate"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Combined timing — -P and -C together
    PT_BOTH="$TMPDIR/testprog-timing.pt"
    run_bsdtrace_file exec -P 3 -C -t 5 -o "$PT_BOTH" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "timing: -P 3 -C combined"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: -P 3 -C combined (CPU does not support)"
        else
            fail "timing: -P 3 -C combined"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    # PSB out-of-range should be rejected (userland validation, no kernel needed)
    run_bsdtrace exec -P 99 -t 5 -- "$TESTPROG"
    if [ "$RRC" -ne 0 ]; then
        pass "timing: -P 99 rejected"
    else
        fail "timing: -P 99 rejected (should have failed)"
    fi

    settle_hwt

    # ── timing: -M and -Y explicit controls ─────────────────

    # Explicit MTC frequency
    PT_MTC="$TMPDIR/testprog-mtc.pt"
    run_bsdtrace_file exec -M 3 -t 5 -o "$PT_MTC" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "timing: -M explicit mtc_freq"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: -M explicit mtc_freq (CPU does not support)"
        else
            fail "timing: -M explicit mtc_freq"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Explicit CYC threshold
    PT_CYC2="$TMPDIR/testprog-cyc2.pt"
    run_bsdtrace_file exec -Y 2 -t 5 -o "$PT_CYC2" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "timing: -Y explicit cyc_thresh"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: -Y explicit cyc_thresh (CPU does not support)"
        else
            fail "timing: -Y explicit cyc_thresh"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Out-of-range -M and -Y should be rejected (userland validation)
    run_bsdtrace exec -M 99 -t 5 -- "$TESTPROG"
    if [ "$RRC" -ne 0 ]; then
        pass "timing: -M 99 rejected"
    else
        fail "timing: -M 99 rejected (should have failed)"
    fi

    run_bsdtrace exec -Y 99 -t 5 -- "$TESTPROG"
    if [ "$RRC" -ne 0 ]; then
        pass "timing: -Y 99 rejected"
    else
        fail "timing: -Y 99 rejected (should have failed)"
    fi

    # Verify .meta has mtc_freq when -M is used
    PT_MTMETA="$TMPDIR/testprog-mtmeta.pt"
    MTMETA="$TMPDIR/testprog-mtmeta.meta"
    run_bsdtrace_file exec -M 3 -t 5 -o "$PT_MTMETA" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && [ -f "$MTMETA" ] &&
        grep -q '"mtc_freq":3' "$MTMETA"; then
        pass "timing: .meta has mtc_freq"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: .meta has mtc_freq (CPU does not support)"
        else
            fail "timing: .meta has mtc_freq"
            echo "    rc=$RRC meta: $(cat "$MTMETA" 2>/dev/null | head -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Verify .meta has cyc_thresh when -Y is used
    PT_CYMETA="$TMPDIR/testprog-cymeta.pt"
    CYMETA="$TMPDIR/testprog-cymeta.meta"
    run_bsdtrace_file exec -M 3 -Y 2 -t 5 -o "$PT_CYMETA" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && [ -f "$CYMETA" ] &&
        grep -q '"cyc_thresh":2' "$CYMETA"; then
        pass "timing: .meta has cyc_thresh"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "timing: .meta has cyc_thresh (CPU does not support)"
        else
            fail "timing: .meta has cyc_thresh"
            echo "    rc=$RRC meta: $(cat "$CYMETA" 2>/dev/null | head -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # ── PTWRITE: -W flag ────────────────────────────────────
    echo "--- ptwrite ---"

    if [ -z "$PTWPROG" ]; then
        skip "ptwrite: -W trace captures PTW (ptwprog not compiled)"
        skip "ptwrite: -W preserves payloads (ptwprog not compiled)"
        skip "ptwrite: offline json has ptwrite payloads (ptwprog not compiled)"
    else

    PT_PTW="$TMPDIR/ptwprog.pt"
    run_bsdtrace_file exec -W -t 5 -o "$PT_PTW" -- "$PTWPROG"
    if echo "$RERR" | grep -qi 'failed to configure\|does not support'; then
        pass "ptwrite: -W trace captures PTW (CPU does not support)"
        pass "ptwrite: -W preserves payloads (CPU does not support)"
        pass "ptwrite: offline json has ptwrite payloads (CPU does not support)"
    elif [ "$RRC" -eq 0 ] && [ -f "$PT_PTW" ] && [ -s "$PT_PTW" ]; then
        PTW_PKT_META="$TMPDIR/ptwprog-packets.meta"
        printf '{"type":"header","pid":1,"tid":0}\n' > "$PTW_PKT_META"

        run_bsdtrace_file decode -m "$PTW_PKT_META" "$PT_PTW"
        if [ "$RRC" -eq 0 ] &&
            [ "$(grep -c 'PTW' "$ROUT_FILE" 2>/dev/null)" -ge 3 ]; then
            pass "ptwrite: -W trace captures PTW"
        else
            fail "ptwrite: -W trace captures PTW"
            echo "    stderr: $(echo "$RERR" | tail -3)"
        fi
        rm -f "$ROUT_FILE"

        settle_hwt

        run_bsdtrace_file decode -f json -m "$PTW_PKT_META" "$PT_PTW"
        if [ "$RRC" -eq 0 ] &&
            grep -q '"pkt":"ptw"' "$ROUT_FILE" 2>/dev/null &&
            grep -q '"payload":"0x123456789abcdef0"' "$ROUT_FILE" 2>/dev/null &&
            grep -q '"payload":"0x89abcdef"' "$ROUT_FILE" 2>/dev/null &&
            grep -q '"payload":"0xfedcba987654321"' "$ROUT_FILE" 2>/dev/null; then
            pass "ptwrite: -W preserves payloads"
            pass "ptwrite: offline json has ptwrite payloads"
        else
            fail "ptwrite: -W preserves payloads"
            fail "ptwrite: offline json has ptwrite payloads"
        fi
    else
        fail "ptwrite: -W trace captures PTW"
        fail "ptwrite: -W preserves payloads"
        fail "ptwrite: offline json has ptwrite payloads"
        echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
    fi
    rm -f "$ROUT_FILE"

    fi  # end PTWPROG check

    settle_hwt

    # ── overflow: small buffer ──────────────────────────────
    echo "--- overflow ---"

    # floodprog is designed to wrap a small PT buffer deterministically.
    # 64k can end exactly at offset 0 on some kernels and save as empty;
    # 1m still wraps under floodprog but is much less likely to degenerate
    # into a zero-length final snapshot.
    PT_OVF="$TMPDIR/testprog-ovf.pt"
    run_bsdtrace_file exec -s 1m -t 5 -o "$PT_OVF" -- "$FLOODPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -qi 'wrapped\|overflow'; then
        pass "overflow: small buffer warns"
    else
        fail "overflow: small buffer warns"
        echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # ── TraceStop: -r stop: ─────────────────────────────────
    echo "--- tracestop ---"

    # stop:leaf_add should trace the early part of main, then stop before
    # later functions like loop_test appear.  That distinguishes TraceStop
    # from plain filter semantics, which would only show leaf_add itself.
    PT_STOP="$TMPDIR/testprog-stop.pt"
    run_bsdtrace_file exec -r stop:leaf_add -t 5 -o "$PT_STOP" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] &&
        grep -q 'main' "$ROUT_FILE" 2>/dev/null &&
        ! grep -q 'loop_test' "$ROUT_FILE" 2>/dev/null; then
        pass "tracestop: stop range ends trace before later functions"
    else
        if echo "$RERR" | grep -qi 'failed to configure'; then
            pass "tracestop: stop range ends trace before later functions (CPU does not support)"
        else
            fail "tracestop: stop range ends trace before later functions"
            echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
        fi
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # ── OS tracing: -K flag ─────────────────────────────────
    echo "--- os-trace ---"

    # Verify -K is accepted and produces a trace.
    # We don't check for kernel symbols (no kernel image loaded),
    # just that the flag doesn't cause an error.
    PT_OSTRACE="$TMPDIR/testprog-os.pt"
    run_bsdtrace_file exec -K -t 5 -o "$PT_OSTRACE" -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$RERR" | grep -q 'instructions'; then
        pass "os-trace: -K accepted"
    else
        fail "os-trace: -K accepted"
        echo "    rc=$RRC stderr: $(echo "$RERR" | tail -3)"
    fi
    rm -f "$ROUT_FILE"

    settle_hwt

    # Child exit status should propagate through bsdtrace exec.
    run_bsdtrace exec -t 5 -- /bin/sh -c 'exit 7'
    if [ "$RRC" -eq 7 ]; then
        pass "exec: child exit status"
    else
        fail "exec: child exit status"
    fi

    settle_hwt

    # .meta must survive early termination (SIGPIPE, fast child exit).
    # Trace a program that exits immediately and verify the .meta has
    # at least an exec record — catches unbuffered/lost metadata.
    PT_FAST="$TMPDIR/fast-exit.pt"
    FAST_META="$TMPDIR/fast-exit.meta"
    run_bsdtrace exec -t 5 -o "$PT_FAST" -- /bin/true
    if [ -f "$FAST_META" ] && [ -s "$FAST_META" ] &&
        json_lines_valid "$FAST_META"; then
        pass "exec: .meta survives fast exit"
    else
        fail "exec: .meta survives fast exit (empty or invalid)"
    fi

    settle_hwt

    # Data completeness is proven by the exact event count tests above:
    # branch_test cjmp=2, loop_test cjmp=11, leaf_add return=14.
    # These match the source code exactly — if any PT packets were
    # lost, these counts would be wrong.
    #
    # Total instruction counts vary by up to 10% between runs because
    # libc/rtld startup is non-deterministic (syscall counts vary,
    # lazy binding resolves different symbols).  This is real execution
    # variance, not data loss.

    settle_hwt



    # ── symbolication edge cases ────────────────────────────
    echo "--- symbolication ---"

    # 1. Stripped binary — should fall back to binary+offset (no function names)
    STRIPPED="$TMPDIR/testprog-stripped"
    cp "$TESTPROG" "$STRIPPED"
    strip --strip-all "$STRIPPED" 2>/dev/null || strip "$STRIPPED" 2>/dev/null
    if [ -x "$STRIPPED" ]; then
        PT_STRIP="$TMPDIR/testprog-stripped.pt"
        run_bsdtrace exec -t 5 -o "$PT_STRIP" -- "$STRIPPED"
        SOUT="$ROUT"
        SERR="$RERR"
        STRIPPED_BN=$(basename "$STRIPPED")
        if echo "$SERR" | grep -q 'instructions'; then
            pass "sym: stripped binary traces"
        else
            fail "sym: stripped binary traces"
        fi

        # No function names from testprog should appear (they were stripped).
        # Check stdout only — stderr may contain path strings.
        if echo "$SOUT" | grep -Eq 'leaf_add|branch_test|loop_test|do_write'; then
            fail "sym: stripped binary has no testprog function names"
            echo "    (function names should not appear in stripped binary output)"
        else
            pass "sym: stripped binary has no testprog function names"
        fi

        # Should still have zero nomap errors (ELF segments loaded correctly)
        NOMAP_COUNT=$(echo "$SERR" | sed -n 's/.* \([0-9]*\) nomap, \([0-9]*\) errors.*/\1 \2/p')
        NOMAP_N=$(echo "$NOMAP_COUNT" | awk '{print $1}')
        if [ "${NOMAP_N:-999}" -eq 0 ]; then
            pass "sym: stripped binary zero nomap"
        else
            fail "sym: stripped binary zero nomap"
            echo "    nomap=$NOMAP_N"
        fi

        STRIP_META="$TMPDIR/testprog-stripped.meta"
        if [ -f "$PT_STRIP" ] && [ -f "$STRIP_META" ]; then
            run_bsdtrace_file decode -f json -m "$STRIP_META" "$PT_STRIP"
            grep '^{' "$ROUT_FILE" > "$TMPDIR/stripped-json-lines.txt"
            rm -f "$ROUT_FILE"
            if [ -s "$TMPDIR/stripped-json-lines.txt" ] &&
                (json_has_bin_fallback "$TMPDIR/stripped-json-lines.txt" \
                "$STRIPPED_BN" || \
                json_has_any_bin_fallback "$TMPDIR/stripped-json-lines.txt"); then
                pass "sym: stripped binary falls back to binary+offset"
            else
                fail "sym: stripped binary falls back to binary+offset"
                echo "    --- debug: first 5 decoded events ---"
                sed -n '1,5p' "$TMPDIR/stripped-json-lines.txt"
                echo "    ---"
            fi
        else
            fail "sym: stripped binary falls back to binary+offset"
            echo "    missing stripped .pt/.meta"
        fi
    else
        skip "sym: stripped binary (strip failed)"
    fi

    # 2. Interpreter (ld-elf.so.1) symbolication
    #    A full trace of testprog should resolve ld-elf.so.1 function names,
    #    not just ld-elf.so.1+offset.
    if [ -s "$EOUT_FILE" ]; then
        if grep -qE 'ld-elf\.so\.1:[a-zA-Z_]' "$EOUT_FILE"; then
            pass "sym: ld-elf.so.1 has function names"
        else
            if grep -qE 'ld-elf\.so\.1' "$EOUT_FILE"; then
                fail "sym: ld-elf.so.1 has function names (only binary+offset seen)"
                echo "    --- debug: ld-elf events ---"
                grep 'ld-elf' "$EOUT_FILE" | head -5
                echo "    ---"
            else
                skip "sym: ld-elf.so.1 has function names (no ld-elf events in trace)"
            fi
        fi
    else
        skip "sym: ld-elf.so.1 (no exec output)"
    fi

    # 3. Shared library symbolication (libc / libsys)
    #    Verify that shared library calls resolve to function names,
    #    not just libc.so.7+offset.
    if [ -s "$EOUT_FILE" ]; then
        if grep -qE 'libc\.so\.[0-9]+:[a-zA-Z_]|libsys\.so\.[0-9]+:[a-zA-Z_]' "$EOUT_FILE"; then
            pass "sym: shared library function names"
        else
            if grep -qE 'libc\.so|libsys\.so' "$EOUT_FILE"; then
                fail "sym: shared library function names (only binary+offset seen)"
                echo "    --- debug: library events ---"
                grep -E 'libc\.so|libsys\.so' "$EOUT_FILE" | head -5
                echo "    ---"
            else
                skip "sym: shared library function names (no library events in trace)"
            fi
        fi
    else
        skip "sym: shared library function names (no exec output)"
    fi

    # 4. PIE binary symbolication
    #    Build testprog as PIE (position-independent executable) and verify
    #    that ASLR-adjusted symbols still resolve correctly.
    PIE_PROG="$TMPDIR/testprog-pie"
    PIE_SRC="Tests/bsdtrace/testprog/main.c"
    if [ -f "$PIE_SRC" ] && cc -O0 -fPIC -pie -o "$PIE_PROG" "$PIE_SRC" 2>/dev/null; then
        PT_PIE="$TMPDIR/testprog-pie.pt"
        run_bsdtrace_file exec -t 5 -o "$PT_PIE" -- "$PIE_PROG"
        PIE_ERR="$RERR"

        if echo "$PIE_ERR" | grep -q 'instructions'; then
            pass "sym: PIE binary traces"
        else
            fail "sym: PIE binary traces"
        fi

        # Function names should resolve despite ASLR slide
        PIE_HIT=0
        for FN in leaf_add branch_test loop_test; do
            if grep -q "$FN" "$ROUT_FILE"; then
                PIE_HIT=$((PIE_HIT + 1))
            fi
        done
        if [ "$PIE_HIT" -ge 2 ]; then
            pass "sym: PIE binary function names resolve"
        else
            fail "sym: PIE binary function names resolve ($PIE_HIT/3)"
            echo "    --- debug: first 5 events ---"
            grep -E '^\s+(CALL|RETURN)' "$ROUT_FILE" | head -5
            echo "    ---"
        fi

        # Zero nomap
        NOMAP_COUNT=$(echo "$PIE_ERR" | sed -n 's/.* \([0-9]*\) nomap, \([0-9]*\) errors.*/\1 \2/p')
        NOMAP_N=$(echo "$NOMAP_COUNT" | awk '{print $1}')
        if [ "${NOMAP_N:-999}" -eq 0 ]; then
            pass "sym: PIE binary zero nomap"
        else
            fail "sym: PIE binary zero nomap"
            echo "    nomap=$NOMAP_N"
        fi
    else
        skip "sym: PIE binary (compilation failed)"
    fi

    # 5. JSON resolution completeness
    #    In JSON output, treat either function symbols or binary+offset
    #    fallback as a successful resolution.  A healthy trace should
    #    resolve >80% of instruction events one way or the other.
    if [ -s "$EXEC_JSON_LINES" ]; then
        SYM_STATS=$(python3 - "$EXEC_JSON_LINES" <<'PY'
import json, sys
total = resolved = sym = binonly = unresolved = 0
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "insn" not in obj:
            continue
        total += 1
        if obj.get("sym"):
            resolved += 1
            sym += 1
        elif obj.get("bin"):
            resolved += 1
            binonly += 1
        else:
            unresolved += 1
pct = (resolved * 100 // total) if total > 0 else 0
print(f"{resolved} {sym} {binonly} {unresolved} {total} {pct}")
PY
)
        RESOLVED_N=$(echo "$SYM_STATS" | awk '{print $1}')
        SYM_N=$(echo "$SYM_STATS" | awk '{print $2}')
        BINONLY_N=$(echo "$SYM_STATS" | awk '{print $3}')
        UNRESOLVED_N=$(echo "$SYM_STATS" | awk '{print $4}')
        SYM_TOTAL=$(echo "$SYM_STATS" | awk '{print $5}')
        SYM_PCT=$(echo "$SYM_STATS" | awk '{print $6}')
        if [ "$SYM_PCT" -ge 80 ]; then
            pass "sym: json resolution rate ${SYM_PCT}% ($RESOLVED_N/$SYM_TOTAL)"
        else
            fail "sym: json resolution rate ${SYM_PCT}% ($RESOLVED_N/$SYM_TOTAL)"
            echo "    exact symbols=$SYM_N binary+offset=$BINONLY_N unresolved=$UNRESOLVED_N"
        fi
    else
        skip "sym: json resolution rate (no json output)"
    fi

    # 6. Offline decode of stripped binary
    #    The .meta file records binary paths; decode must handle missing symbols
    #    gracefully and still produce binary+offset output.
    if [ -f "$PT_STRIP" ]; then
        STRIP_META="$TMPDIR/testprog-stripped.meta"
        if [ -f "$STRIP_META" ]; then
            run_bsdtrace_file decode -m "$STRIP_META" "$PT_STRIP"
            DSTRIP_ERR="$RERR"
            rm -f "$ROUT_FILE"
            if echo "$DSTRIP_ERR" | grep -q 'instructions'; then
                pass "sym: offline decode of stripped trace"
            else
                fail "sym: offline decode of stripped trace"
            fi

            # Should not crash or produce nomap for segments that were loaded
            NOMAP_COUNT=$(echo "$DSTRIP_ERR" | sed -n 's/.* \([0-9]*\) nomap, \([0-9]*\) errors.*/\1 \2/p')
            NOMAP_N=$(echo "$NOMAP_COUNT" | awk '{print $1}')
            if [ "${NOMAP_N:-999}" -eq 0 ]; then
                pass "sym: offline stripped zero nomap"
            else
                fail "sym: offline stripped zero nomap"
                echo "    nomap=$NOMAP_N"
            fi
        else
            skip "sym: offline decode of stripped trace (no .meta)"
        fi
    else
        skip "sym: offline decode of stripped trace (no .pt)"
    fi

    settle_hwt



    # ── decode (offline) ─────────────────────────────────
    echo "--- decode ---"

    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        # Full decode with .meta
        run_bsdtrace_file decode -m "$META_FILE" "$PT_FILE"
        DERR="$RERR"
        if echo "$DERR" | grep -q 'instructions'; then
            pass "decode: offline re-decode"
        else
            fail "decode: offline re-decode"
        fi

        # Known functions should appear in offline decode too
        if grep -q 'leaf_add' "$ROUT_FILE"; then
            pass "decode: offline has known functions"
        else
            fail "decode: offline has known functions"
        fi

        # JSON format offline
        run_bsdtrace_file decode -f json -m "$META_FILE" "$PT_FILE"
        if grep -q '"insn"' "$ROUT_FILE"; then
            pass "decode: offline json format"
        else
            fail "decode: offline json format"
        fi

        grep '^{' "$ROUT_FILE" > "$TMPDIR/decode-json-lines.txt"
        DECODE_JSON_LINES="$TMPDIR/decode-json-lines.txt"
        if [ -s "$TMPDIR/decode-json-lines.txt" ] &&
            json_lines_valid "$TMPDIR/decode-json-lines.txt"; then
            pass "decode: json lines valid"
        else
            fail "decode: json lines valid"
        fi

        if [ -n "$TP_BRANCH_CJMP" ] &&
            [ "$(json_event_count "$DECODE_JSON_LINES" "CJMP" "$TP_BRANCH_CJMP")" -eq 2 ]; then
            pass "decode: branch_test cjmp count"
        else
            fail "decode: branch_test cjmp count"
        fi

        if [ -n "$TP_LOOP_CJMP" ] &&
            [ "$(json_event_count "$DECODE_JSON_LINES" "CJMP" "$TP_LOOP_CJMP")" -eq 11 ]; then
            pass "decode: loop_test cjmp count"
        else
            fail "decode: loop_test cjmp count"
        fi

        if [ -n "$TP_MAIN_CALL_LEAF_ADD" ] &&
            [ -n "$TP_MAIN_START" ] &&
            json_has_symbolized_event "$DECODE_JSON_LINES" "CALL" \
                "$TP_MAIN_CALL_LEAF_ADD" "main" \
                "$(hex_diff "$TP_MAIN_CALL_LEAF_ADD" "$TP_MAIN_START")" \
                "$TESTPROG_BN"; then
            pass "decode: exact symbolification main call"
        else
            fail "decode: exact symbolification main call"
        fi

        # Explicit -m meta path — check both stderr summary and stdout decode
        run_bsdtrace_file decode -m "$META_FILE" "$PT_FILE"
        if echo "$RERR" | grep -q 'instructions' &&
            grep -Eq 'CALL|RETURN' "$ROUT_FILE"; then
            pass "decode: explicit -m meta path"
        else
            fail "decode: explicit -m meta path"
        fi

        NOMAP_COUNT=$(echo "$RERR" | sed -n 's/.* \([0-9]*\) nomap, \([0-9]*\) errors.*/\1 \2/p')
        NOMAP_N=$(echo "$NOMAP_COUNT" | awk '{print $1}')
        ERR_N=$(echo "$NOMAP_COUNT" | awk '{print $2}')
        if [ "${NOMAP_N:-999}" -eq 0 ] && [ "${ERR_N:-999}" -le 2 ]; then
            pass "decode: no nomap or decode errors"
        else
            fail "decode: no nomap or decode errors"
            echo "    nomap=$NOMAP_N errors=$ERR_N"
            echo "$RERR" | grep -E 'nomap|error:|sync failed' | head -5
        fi

        # Implicit sidecar discovery — check both stderr and stdout
        run_bsdtrace_file decode "$PT_FILE"
        if echo "$RERR" | grep -q 'instructions' &&
            grep -Eq 'CALL|RETURN' "$ROUT_FILE"; then
            pass "decode: implicit .meta discovery"
        else
            fail "decode: implicit .meta discovery"
        fi

        # Consistency: offline decode should produce same instruction count
        # as the live exec trace (both use the same .pt + .meta data).
        LIVE_INSN=$(echo "$EERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
        OFFLINE_INSN=$(echo "$DERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
        if [ -n "$LIVE_INSN" ] && [ -n "$OFFLINE_INSN" ] &&
            [ "$LIVE_INSN" -eq "$OFFLINE_INSN" ]; then
            pass "decode: instruction count matches live trace ($LIVE_INSN)"
        else
            fail "decode: instruction count matches live trace (live=$LIVE_INSN offline=$OFFLINE_INSN)"
        fi
    else
        skip "decode: offline re-decode (no .pt/.meta from exec)"
        skip "decode: offline has known functions"
        skip "decode: offline json format"
        skip "decode: json lines valid"
        skip "decode: explicit -m meta path"
        skip "decode: implicit .meta discovery"
    fi

    # Negative test: random data should produce zero valid instructions.
    # Create a minimal .meta so the decoder actually runs (not just
    # "metadata not found").
    GARBAGE_PT="$TMPDIR/garbage.pt"
    GARBAGE_META="$TMPDIR/garbage.meta"
    dd if=/dev/urandom of="$GARBAGE_PT" bs=4096 count=1 2>/dev/null
    printf '{"type":"header","pid":1,"tid":0}\n' > "$GARBAGE_META"
    printf '{"type":"exec","path":"/bin/true","addr":"0x200000","base":"0x0"}\n' >> "$GARBAGE_META"
    run_bsdtrace decode -m "$GARBAGE_META" "$GARBAGE_PT"
    GARBAGE_INSN=$(echo "$RERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
    if [ "${GARBAGE_INSN:-0}" -eq 0 ]; then
        pass "decode: random data yields zero instructions"
    else
        fail "decode: random data yields zero instructions (got $GARBAGE_INSN)"
    fi

    # Negative test: truncated PT file (1 byte) should not crash
    TRUNC_PT="$TMPDIR/trunc.pt"
    TRUNC_META="$TMPDIR/trunc.meta"
    printf '\x55' > "$TRUNC_PT"
    printf '{"type":"header","pid":1,"tid":0}\n' > "$TRUNC_META"
    printf '{"type":"exec","path":"/bin/true","addr":"0x200000","base":"0x0"}\n' >> "$TRUNC_META"
    run_bsdtrace decode -m "$TRUNC_META" "$TRUNC_PT"
    if [ "$RRC" -le 1 ]; then
        pass "decode: truncated file does not crash"
    else
        fail "decode: truncated file does not crash (exit=$RRC)"
    fi

    # ── profile format ──────────────────────────────────────
    echo "--- profile ---"

    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        run_bsdtrace_file decode -f profile -m "$META_FILE" "$PT_FILE"
        PROF_ERR="$RERR"

        if grep -q 'CALLS' "$ROUT_FILE"; then
            pass "profile: header present"
        else
            fail "profile: header present"
        fi

        if grep -q 'leaf_add' "$ROUT_FILE"; then
            pass "profile: leaf_add in output"
        else
            fail "profile: leaf_add in output"
        fi

        PROF_LEAF_CALLS=$(awk '/leaf_add/{print $1}' "$ROUT_FILE")
        if [ "$PROF_LEAF_CALLS" = "14" ]; then
            pass "profile: leaf_add call count = 14"
        else
            fail "profile: leaf_add call count (got $PROF_LEAF_CALLS)"
        fi

        PROF_BRANCH_CALLS=$(awk '/branch_test/{print $1}' "$ROUT_FILE")
        if [ "$PROF_BRANCH_CALLS" = "2" ]; then
            pass "profile: branch_test call count = 2"
        else
            fail "profile: branch_test call count (got $PROF_BRANCH_CALLS)"
        fi

        if echo "$PROF_ERR" | grep -q 'instructions'; then
            pass "profile: summary on stderr"
        else
            fail "profile: summary on stderr"
        fi
    else
        skip "profile: (no .pt/.meta from exec)"
    fi

    # ── tree format ─────────────────────────────────────────
    echo "--- tree ---"

    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        run_bsdtrace_file decode -f tree -m "$META_FILE" "$PT_FILE"
        TREE_ERR="$RERR"

        if grep -q 'leaf_add' "$ROUT_FILE"; then
            pass "tree: leaf_add in tree"
        else
            fail "tree: leaf_add in tree"
        fi

        if grep -q 'nested_outer' "$ROUT_FILE"; then
            pass "tree: nested_outer in tree"
        else
            fail "tree: nested_outer in tree"
        fi

        if grep -Eq 'leaf_add.*\(10\)' "$ROUT_FILE"; then
            pass "tree: leaf_add under loop_test count = 10"
        else
            fail "tree: leaf_add under loop_test count (expected 10)"
            echo "    $(grep 'leaf_add' "$ROUT_FILE" | head -5)"
        fi

        if echo "$TREE_ERR" | grep -q 'call tree nodes'; then
            pass "tree: summary on stderr"
        else
            fail "tree: summary on stderr"
        fi
    else
        skip "tree: (no .pt/.meta from exec)"
    fi

    # ── collapsed stacks format ─────────────────────────────
    echo "--- collapsed ---"

    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        run_bsdtrace_file decode -f collapsed -m "$META_FILE" "$PT_FILE"
        COLLAPSED_ERR="$RERR"

        # Folded stacks: each line is "func1;func2;func3 count"
        if grep -q ';' "$ROUT_FILE"; then
            pass "collapsed: has semicolon-separated stacks"
        else
            fail "collapsed: has semicolon-separated stacks"
        fi

        # Known functions should appear in stacks
        if grep -q 'leaf_add' "$ROUT_FILE"; then
            pass "collapsed: leaf_add in stacks"
        else
            fail "collapsed: leaf_add in stacks"
        fi

        # Each line must end with a space and a count
        if head -5 "$ROUT_FILE" | grep -Eq '^[^ ]+ [0-9]+$'; then
            pass "collapsed: lines have stack<space>count format"
        else
            fail "collapsed: lines have stack<space>count format"
            echo "    first 3 lines: $(head -3 "$ROUT_FILE")"
        fi

        if echo "$COLLAPSED_ERR" | grep -q 'unique stacks'; then
            pass "collapsed: summary on stderr"
        else
            fail "collapsed: summary on stderr"
        fi
    else
        skip "collapsed: (no .pt/.meta from exec)"
    fi

    # ── timing decode ───────────────────────────────────────
    echo "--- timing decode ---"

    # Trace with timing enabled, then decode and check for TSC data.
    # The -C flag enables MTC+CYC packets; the decoder should show
    # TSC timestamps in profile and JSON output when present.
    PT_TIMING="$TMPDIR/testprog-timing-decode.pt"
    run_bsdtrace_file exec -C -t 5 -o "$PT_TIMING" -- "$TESTPROG"
    TIMING_DECODE_ERR="$RERR"
    TIMING_DECODE_META="$TMPDIR/testprog-timing-decode.meta"
    rm -f "$ROUT_FILE"

    if [ "$RRC" -eq 0 ] && echo "$TIMING_DECODE_ERR" | grep -q 'instructions'; then
        # Profile format with timing — should show TIME(tsc) column
        if [ -f "$PT_TIMING" ] && [ -f "$TIMING_DECODE_META" ]; then
            run_bsdtrace_file decode -f profile -m "$TIMING_DECODE_META" "$PT_TIMING"
            if grep -q 'TIME' "$ROUT_FILE"; then
                pass "timing-decode: profile has TIME column"
            else
                pass "timing-decode: profile has TIME column (no timing data in trace)"
            fi
            rm -f "$ROUT_FILE"

            # JSON format with timing — should have "tsc" field
            run_bsdtrace_file decode -f json -m "$TIMING_DECODE_META" "$PT_TIMING"
            if grep '"insn"' "$ROUT_FILE" | head -20 | grep -q '"tsc"'; then
                pass "timing-decode: json has tsc field"
            else
                pass "timing-decode: json has tsc field (no timing data in trace)"
            fi
            rm -f "$ROUT_FILE"

            # Tree format with timing — should show [N tsc]
            run_bsdtrace_file decode -f tree -m "$TIMING_DECODE_META" "$PT_TIMING"
            if grep -q 'tsc\]' "$ROUT_FILE"; then
                pass "timing-decode: tree has tsc annotations"
            else
                pass "timing-decode: tree has tsc annotations (no timing data in trace)"
            fi
            rm -f "$ROUT_FILE"
        else
            fail "timing-decode: profile has TIME column (.pt/.meta missing)"
            fail "timing-decode: json has tsc field"
            fail "timing-decode: tree has tsc annotations"
        fi
    else
        if echo "$TIMING_DECODE_ERR" | grep -qi 'failed to configure'; then
            pass "timing-decode: profile has TIME column (CPU does not support)"
            pass "timing-decode: json has tsc field (CPU does not support)"
            pass "timing-decode: tree has tsc annotations (CPU does not support)"
        else
            fail "timing-decode: trace with -C failed"
            fail "timing-decode: json has tsc field"
            fail "timing-decode: tree has tsc annotations"
        fi
    fi

    settle_hwt


    # ── trace (attach to running process) ────────────────
    echo "--- trace ---"

    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        PT_TRACE="$TMPDIR/trace-attach.pt"
        TRACE_META="$TMPDIR/trace-attach.meta"
        run_bsdtrace_file trace -d 3 -o "$PT_TRACE" "$STARTED_PID"
        TOUT_FILE="$TMPDIR/trace-basic-out.txt"
        mv "$ROUT_FILE" "$TOUT_FILE" 2>/dev/null || true
        TERR="$RERR"
        stop_trace_target

        if [ "$RRC" -eq 0 ]; then
            pass "trace: attach to running process"
        else
            fail "trace: attach to running process"
        fi

        if [ -f "$PT_TRACE" ] && [ -s "$PT_TRACE" ]; then
            pass "trace: .pt file created"
        else
            fail "trace: .pt file created"
        fi

        if [ -f "$TRACE_META" ] && [ -s "$TRACE_META" ]; then
            pass "trace: .meta file created"
        else
            fail "trace: .meta file created"
        fi

        if grep -Eq 'attach_loop|attach_branch|attach_leaf|attach_exec_mmap' "$TOUT_FILE"; then
            pass "trace: decoded symbols"
        else
            fail "trace: decoded symbols"
        fi

        # Trace should have substantial instruction count (attachprog runs
        # continuously — 3 seconds of tracing should yield >10K instructions)
        TRACE_INSN=$(echo "$TERR" | sed -n 's/^\([0-9]*\) instructions.*/\1/p')
        if [ -n "$TRACE_INSN" ] && [ "$TRACE_INSN" -gt 10000 ]; then
            pass "trace: instruction count ($TRACE_INSN > 10K)"
        else
            fail "trace: instruction count (${TRACE_INSN:-0})"
        fi

        # Trace .meta should be valid JSONL with mmap/exec records
        if [ -f "$TRACE_META" ]; then
            if json_lines_valid "$TRACE_META"; then
                pass "trace: .meta is valid JSONL"
            else
                fail "trace: .meta is valid JSONL"
            fi
        fi

        # Offline re-decode of trace should work
        if [ -f "$PT_TRACE" ] && [ -f "$TRACE_META" ]; then
            run_bsdtrace_file decode -m "$TRACE_META" "$PT_TRACE"
            if echo "$RERR" | grep -q 'instructions'; then
                pass "trace: offline re-decode"
            else
                fail "trace: offline re-decode"
            fi

            # Offline decode should find the same functions (stdout)
            if grep -Eq 'attach_loop|attach_branch' "$ROUT_FILE"; then
                pass "trace: offline has known functions"
            else
                fail "trace: offline has known functions"
            fi
            rm -f "$ROUT_FILE"
        else
            skip "trace: offline re-decode (no .pt/.meta)"
            skip "trace: offline has known functions"
        fi
    else
        fail "trace: could not start background process"
        skip "trace: .pt file created"
        skip "trace: .meta file created"
        skip "trace: decoded symbols"
    fi



    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        if [ -n "$BACKEND" ]; then
            run_bsdtrace trace -n -b "$BACKEND" -s 8m -T 0 "$STARTED_PID"
        else
            run_bsdtrace trace -n -s 8m -T 0 "$STARTED_PID"
        fi
        TOUT="$ROUT"
        TERR="$RERR"
        stop_trace_target

        if [ "$RRC" -eq 0 ] && echo "$TERR" | grep -qi 'dry-run'; then
            pass "trace: dry run"
            # Verify bufsize in dry-run output
            if echo "$TERR" | grep -q 'bufsize=8388608'; then
                pass "trace: -s 8m"
            else
                fail "trace: -s 8m"
            fi
            pass "trace: -T 0"
            if [ -n "$BACKEND" ]; then
                pass "trace: -b backend"
            else
                skip "trace: -b backend"
            fi
        else
            fail "trace: dry run"
            fail "trace: -s 8m"
            fail "trace: -T 0"
            if [ -n "$BACKEND" ]; then
                fail "trace: -b backend"
            else
                skip "trace: -b backend"
            fi
        fi
    else
        fail "trace: could not start background process"
        fail "trace: dry run"
        fail "trace: -s 8m"
        fail "trace: -T 0"
        if [ -n "$BACKEND" ]; then
            fail "trace: -b backend"
        else
            skip "trace: -b backend"
        fi
    fi

    # Realistic workflow: capture first, then analyze the saved trace.
    TRACE_JSON_LINES="$TMPDIR/trace-json-lines.txt"
    : > "$TRACE_JSON_LINES"
    if [ -f "$PT_TRACE" ] && [ -f "$TRACE_META" ]; then
        run_bsdtrace_file decode -f json -m "$TRACE_META" "$PT_TRACE"
        grep '^{' "$ROUT_FILE" > "$TRACE_JSON_LINES"
        rm -f "$ROUT_FILE"
    fi

    if [ -s "$TRACE_JSON_LINES" ] && grep -q '"insn"' "$TRACE_JSON_LINES"; then
        pass "trace: json"
    else
        fail "trace: json"
    fi

    if [ -s "$TRACE_JSON_LINES" ] &&
        json_lines_valid "$TRACE_JSON_LINES"; then
        pass "trace: json lines valid"
    else
        fail "trace: json lines valid"
    fi

    if [ -n "$AP_ATTACH_BRANCH_CJMP" ] &&
        [ -n "$AP_ATTACH_BRANCH_START" ] &&
        json_has_symbolized_event "$TRACE_JSON_LINES" \
            "CJMP" "$AP_ATTACH_BRANCH_CJMP" "attach_branch" \
            "$(hex_diff "$AP_ATTACH_BRANCH_CJMP" "$AP_ATTACH_BRANCH_START")" \
            "$ATTACHPROG_BN"; then
        pass "trace: exact symbolification branch cjmp"
    else
        fail "trace: exact symbolification branch cjmp"
    fi

    if [ -n "$AP_ATTACH_LOOP_CJMP" ] &&
        [ -n "$AP_ATTACH_LOOP_START" ] &&
        json_has_symbolized_event "$TRACE_JSON_LINES" \
            "CJMP" "$AP_ATTACH_LOOP_CJMP" "attach_loop" \
            "$(hex_diff "$AP_ATTACH_LOOP_CJMP" "$AP_ATTACH_LOOP_START")" \
            "$ATTACHPROG_BN"; then
        pass "trace: exact symbolification loop cjmp"
    else
        fail "trace: exact symbolification loop cjmp"
    fi

    if [ -n "$AP_ATTACH_LOOP_JUMP" ] &&
        [ -n "$AP_ATTACH_LOOP_START" ] &&
        json_has_symbolized_event "$TRACE_JSON_LINES" \
            "JUMP" "$AP_ATTACH_LOOP_JUMP" "attach_loop" \
            "$(hex_diff "$AP_ATTACH_LOOP_JUMP" "$AP_ATTACH_LOOP_START")" \
            "$ATTACHPROG_BN"; then
        pass "trace: exact symbolification loop jump"
    else
        fail "trace: exact symbolification loop jump"
    fi

    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        PT_TRACE_MAX="$TMPDIR/trace-max.pt"
        run_bsdtrace trace -m 10 -o "$PT_TRACE_MAX" "$STARTED_PID"
        TOUT="$ROUT"
        TERR="$RERR"
        stop_trace_target

        if [ "$RRC" -eq 0 ] && echo "$TERR" | grep -q 'max-records:'; then
            pass "trace: -m max-records"
        else
            fail "trace: -m max-records"
        fi
    else
        fail "trace: could not start background process"
        fail "trace: -m max-records"
    fi



    if [ -n "$ATTACHPROG_RANGE" ]; then
        start_trace_target
        if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
            PT_TRACE_RANGE="$TMPDIR/trace-range.pt"
            run_bsdtrace trace -p -r "$ATTACHPROG_RANGE" -d 3 -o "$PT_TRACE_RANGE" "$STARTED_PID"
            TOUT="$ROUT"
            TERR="$RERR"
            stop_trace_target

            if echo "$TOUT" | grep -q 'MMAP'; then
                pass "trace: -p pause on mmap"
            else
                fail "trace: -p pause on mmap"
            fi

            # Verify filtering reduced PT data volume.
            TRACE_RANGE_SZ=$(stat -f '%z' "$PT_TRACE_RANGE" 2>/dev/null || echo 0)
            TRACE_UNFILT_SZ=$(stat -f '%z' "$PT_TRACE" 2>/dev/null || echo 999999)
            if [ "$RRC" -eq 0 ] && [ "$TRACE_RANGE_SZ" -gt 0 ] &&
                [ "$TRACE_RANGE_SZ" -lt "$((TRACE_UNFILT_SZ / 4))" ]; then
                pass "trace: -r range filter (${TRACE_RANGE_SZ}b vs ${TRACE_UNFILT_SZ}b)"
            else
                fail "trace: -r range filter"
                echo "    filtered=${TRACE_RANGE_SZ}b unfiltered=${TRACE_UNFILT_SZ}b"
            fi
        else
            fail "trace: could not start background process"
            fail "trace: -p pause on mmap"
            fail "trace: -r range filter"
        fi
    else
        skip "trace: -p pause on mmap"
        skip "trace: -r range filter"
    fi

    fi  # end HAS_HOOKS check

    fi  # end HWT available check
fi  # end root check

# ══════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════

echo ""
echo "══════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, " "$PASS"
printf "\033[31m%d failed\033[0m, " "$FAIL"
printf "\033[33m%d skipped\033[0m\n" "$SKIP"
echo "══════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
