#!/bin/sh
#
# test-bsdtrace.sh — comprehensive test suite for bsdtrace
#
# Two tiers:
#   No-root:  version, list, info, decode error handling
#   Root:     exec, decode, trace (require HWT kernel modules)
#
# Run:
#   sh test-bsdtrace.sh            # no-root tests only
#   doas sh test-bsdtrace.sh       # full suite
#

BIN=".build/x86_64-unknown-freebsd/debug/bsdtrace"
TESTPROG_SRC="Tests/bsdtrace/testprog.c"
TESTPROG="/tmp/bsdtrace-testprog-$$"
ATTACHPROG_SRC="Tests/bsdtrace/attachprog.c"
ATTACHPROG="/tmp/bsdtrace-attachprog-$$"
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

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }

# Run a bsdtrace command with a timeout.  Returns the output in $ROUT
# and the exit code in $RRC.  Prevents a crash/hang from killing the
# test suite.
run_bsdtrace() {
    ROUT=$(timeout "$TIMEOUT" $BIN "$@" 2>&1)
    RRC=$?
    if [ "$RRC" -eq 124 ]; then
        ROUT="TIMEOUT after ${TIMEOUT}s"
    fi
}
skip() { SKIP=$((SKIP + 1)); printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }

json_lines_valid() {
    JSON_FILE=$1
    BAD_JSON=0

    while IFS= read -r line; do
        if [ -z "$line" ]; then
            continue
        fi
        if ! echo "$line" | python3 -m json.tool > /dev/null 2>&1; then
            BAD_JSON=1
            break
        fi
    done < "$JSON_FILE"

    return "$BAD_JSON"
}

text_range_arg() {
    INFO_OUT=$($BIN info "$1" 2>/dev/null)
    RANGE_FIELDS=$(echo "$INFO_OUT" |
        sed -n 's/.*Text: 0x\([0-9a-fA-F]*\) +0x\([0-9a-fA-F]*\).*/\1 \2/p' |
        head -1)
    RANGE_START_HEX=$(echo "$RANGE_FIELDS" | awk '{print $1}')
    RANGE_LEN_HEX=$(echo "$RANGE_FIELDS" | awk '{print $2}')

    if [ -z "$RANGE_START_HEX" ] || [ -z "$RANGE_LEN_HEX" ]; then
        return 1
    fi

    RANGE_START_DEC=$((0x$RANGE_START_HEX))
    RANGE_END_DEC=$((RANGE_START_DEC + 0x$RANGE_LEN_HEX))
    printf '0x%x:0x%x\n' "$RANGE_START_DEC" "$RANGE_END_DEC"
}

start_trace_target() {
    sh -c "sleep 1; exec \"$ATTACHPROG\"" > /dev/null 2>&1 &
    STARTED_PID=$!
    PIDS_TO_KILL="$PIDS_TO_KILL $STARTED_PID"
}

stop_trace_target() {
    if [ -n "$STARTED_PID" ]; then
        kill "$STARTED_PID" 2>/dev/null || true
        wait "$STARTED_PID" 2>/dev/null || true
        STARTED_PID=""
    fi
}

settle_hwt() {
    sleep 3
}

cleanup() {
    for pid in $PIDS_TO_KILL; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TMPDIR"
    rm -f "$TESTPROG"
    rm -f "$ATTACHPROG"
}
trap cleanup EXIT

mkdir -p "$TMPDIR"

echo "=== bsdtrace test suite ==="
echo ""

# ── Build ────────────────────────────────────────────────
echo "--- build ---"

printf "  Building bsdtrace... "
if swift build 2>&1 | tail -1; then
    :
else
    echo "FATAL: swift build failed"
    exit 2
fi

if [ ! -x "$BIN" ]; then
    echo "FATAL: $BIN not found after build"
    exit 2
fi

# Compile testprog
printf "  Compiling testprog... "
if cc -O0 -o "$TESTPROG" "$TESTPROG_SRC" 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile testprog"
    exit 2
fi

printf "  Compiling attachprog... "
if cc -O0 -o "$ATTACHPROG" "$ATTACHPROG_SRC" 2>&1; then
    echo "ok"
else
    echo "FATAL: failed to compile attachprog"
    exit 2
fi

if readelf -h "$TESTPROG" 2>/dev/null | grep -q 'EXEC'; then
    TESTPROG_RANGE=$(text_range_arg "$TESTPROG")
fi

if readelf -h "$ATTACHPROG" 2>/dev/null | grep -q 'EXEC'; then
    ATTACHPROG_RANGE=$(text_range_arg "$ATTACHPROG")
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

# ── info (static ELF) ───────────────────────────────────
echo "--- info (static ELF) ---"

# libc — should have text segments and functions
IOUT=$($BIN info /lib/libc.so.7 2>&1)
if echo "$IOUT" | grep -q 'Text:'; then
    pass "info: libc has Text segment"
else
    fail "info: libc has Text segment"
fi

if echo "$IOUT" | grep -q 'Functions:'; then
    pass "info: libc has Functions count"
else
    fail "info: libc has Functions count"
fi

# ld-elf — dynamic linker
IOUT=$($BIN info /libexec/ld-elf.so.1 2>&1)
if echo "$IOUT" | grep -q 'Text:'; then
    pass "info: ld-elf has Text segment"
else
    fail "info: ld-elf has Text segment"
fi

# testprog — verify our known function names appear
IOUT=$($BIN info "$TESTPROG" 2>&1)
if echo "$IOUT" | grep -q 'Text:'; then
    pass "info: testprog has Text segment"
else
    fail "info: testprog has Text segment"
fi

if echo "$IOUT" | grep -q 'leaf_add'; then
    pass "info: testprog shows leaf_add"
else
    fail "info: testprog shows leaf_add"
fi

if echo "$IOUT" | grep -q 'leaf_mul'; then
    pass "info: testprog shows leaf_mul"
else
    fail "info: testprog shows leaf_mul"
fi

if echo "$IOUT" | grep -q 'nested_outer'; then
    pass "info: testprog shows nested_outer"
else
    fail "info: testprog shows nested_outer"
fi

if echo "$IOUT" | grep -q 'nested_inner'; then
    pass "info: testprog shows nested_inner"
else
    fail "info: testprog shows nested_inner"
fi

if echo "$IOUT" | grep -q 'branch_test'; then
    pass "info: testprog shows branch_test"
else
    fail "info: testprog shows branch_test"
fi

if echo "$IOUT" | grep -q 'loop_test'; then
    pass "info: testprog shows loop_test"
else
    fail "info: testprog shows loop_test"
fi

if echo "$IOUT" | grep -q 'do_write'; then
    pass "info: testprog shows do_write"
else
    fail "info: testprog shows do_write"
fi

if echo "$IOUT" | grep -q 'main'; then
    pass "info: testprog shows main"
else
    fail "info: testprog shows main"
fi

if echo "$IOUT" | grep -q '.symtab'; then
    pass "info: testprog symbols from .symtab"
else
    # .dynsym is also acceptable for PIE
    if echo "$IOUT" | grep -q '.dynsym'; then
        pass "info: testprog symbols from .dynsym"
    else
        fail "info: testprog has symbol source"
    fi
fi

# Multiple files
IOUT=$($BIN info /lib/libc.so.7 /libexec/ld-elf.so.1 2>&1)
if echo "$IOUT" | grep -c 'Text:' | grep -q '[2-9]'; then
    pass "info: multiple files show multiple Text segments"
else
    fail "info: multiple files show multiple Text segments"
fi

# ── info (PID mode) ─────────────────────────────────────
echo "--- info (pid) ---"

if [ -d /proc/$$ ]; then
    IOUT=$($BIN info -p $$ 2>&1)
    if echo "$IOUT" | grep -q 'PID'; then
        pass "info: -p shows PID header"
    else
        fail "info: -p shows PID header"
    fi

    # Should find at least one executable mapping
    if echo "$IOUT" | grep -q 'Text:'; then
        pass "info: -p finds executable mappings"
    else
        fail "info: -p finds executable mappings"
    fi
else
    skip "info: -p (procfs not mounted)"
    skip "info: -p finds executable mappings"
fi

# ── info (error cases) ──────────────────────────────────
echo "--- info (errors) ---"

# Nonexistent file — should print error, not crash
IOUT=$($BIN info /nonexistent/binary 2>&1)
if [ $? -eq 0 ] || [ -n "$IOUT" ]; then
    pass "info: nonexistent file doesn't crash"
else
    fail "info: nonexistent file doesn't crash"
fi

# No arguments — should print usage
IOUT=$($BIN info 2>&1) || true
if echo "$IOUT" | grep -qi 'usage'; then
    pass "info: no args prints usage"
else
    fail "info: no args prints usage"
fi

# Invalid PID
IOUT=$($BIN info -p 0 2>&1) || true
if echo "$IOUT" | grep -qi 'positive\|usage\|error'; then
    pass "info: -p 0 rejects invalid PID"
else
    fail "info: -p 0 rejects invalid PID"
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
    run_bsdtrace exec -t 5 -o "$PT_FILE" -- "$TESTPROG"
    EOUT="$ROUT"
    if echo "$EOUT" | grep -q 'instructions'; then
        pass "exec: basic trace with decode"
    else
        fail "exec: basic trace with decode"
        echo "    Output: $(echo "$EOUT" | tail -5)"
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

    # Control flow event types
    for EVT in CALL RETURN CJMP SYSCALL; do
        if echo "$EOUT" | grep -q "$EVT"; then
            pass "exec: $EVT events in output"
        else
            fail "exec: $EVT events in output"
        fi
    done

    # Known function names from testprog
    FN_MISS=0
    for FN in leaf_add leaf_mul nested_outer nested_inner \
              branch_test loop_test do_write; do
        if echo "$EOUT" | grep -q "$FN"; then
            pass "exec: $FN in decoded output"
        else
            fail "exec: $FN in decoded output"
            FN_MISS=$((FN_MISS + 1))
        fi
    done
    if [ "$FN_MISS" -gt 0 ]; then
        echo "    --- debug: image build info ---"
        echo "$EOUT" | grep -E '^(image:|  \[)' | head -10
        echo "    --- debug: first 5 decoded events ---"
        echo "$EOUT" | grep -E '^\s+(CALL|RETURN|CJMP|SYSCALL)' | head -5
        echo "    --- debug: testprog ELF layout ---"
        readelf -l "$TESTPROG" 2>/dev/null | grep -A1 'LOAD' | head -6
        echo "    ---"
    fi

    settle_hwt

    # JSON output
    PT_JSON="$TMPDIR/testprog-json.pt"
    run_bsdtrace exec -f json -t 5 -o "$PT_JSON" -- "$TESTPROG"
    JOUT="$ROUT"

    if echo "$JOUT" | grep -q '"insn"'; then
        pass "exec: json has insn field"
    else
        fail "exec: json has insn field"
        echo "    --- debug: json output sample ---"
        echo "$JOUT" | tail -10
        echo "    ---"
    fi

    if echo "$JOUT" | grep -q '"sym"'; then
        pass "exec: json has sym field"
    else
        fail "exec: json has sym field"
    fi

    echo "$JOUT" | grep '^{' > "$TMPDIR/exec-json-lines.txt"
    if [ -s "$TMPDIR/exec-json-lines.txt" ] &&
        json_lines_valid "$TMPDIR/exec-json-lines.txt"; then
        pass "exec: json lines are valid JSON"
    else
        fail "exec: json lines are valid JSON"
    fi

    settle_hwt

    # Thread selection
    PT_TID="$TMPDIR/testprog-tid.pt"
    run_bsdtrace exec -T 0 -t 5 -o "$PT_TID" -- "$TESTPROG"
    if echo "$ROUT" | grep -q 'instructions'; then
        pass "exec: thread selection -T 0"
    else
        fail "exec: thread selection -T 0"
    fi

    settle_hwt

    # Disable ASLR
    PT_ASLR="$TMPDIR/testprog-aslr.pt"
    run_bsdtrace exec -A -t 5 -o "$PT_ASLR" -- "$TESTPROG"
    if echo "$ROUT" | grep -q 'instructions'; then
        pass "exec: disable ASLR -A"
    else
        fail "exec: disable ASLR -A"
    fi

    settle_hwt

    # Dry run
    run_bsdtrace exec -n -t 5 -- "$TESTPROG"
    if [ "$RRC" -eq 0 ] && echo "$ROUT" | grep -qi 'dry-run'; then
        pass "exec: dry run -n"
    else
        fail "exec: dry run -n"
    fi

    settle_hwt

    # Custom buffer size
    PT_BUF="$TMPDIR/testprog-buf.pt"
    run_bsdtrace exec -s 8m -t 5 -o "$PT_BUF" -- "$TESTPROG"
    if echo "$ROUT" | grep -q 'instructions'; then
        pass "exec: custom buffer size -s 8m"
    else
        fail "exec: custom buffer size -s 8m"
    fi

    settle_hwt

    # Custom output path
    PT_CUSTOM="$TMPDIR/custom-output.pt"
    run_bsdtrace exec -t 5 -o "$PT_CUSTOM" -- "$TESTPROG"
    if [ -f "$PT_CUSTOM" ] && [ -s "$PT_CUSTOM" ]; then
        pass "exec: custom output path -o"
    else
        fail "exec: custom output path -o"
    fi

    settle_hwt

    # Explicit backend and pause-on-mmap
    if [ -n "$BACKEND" ]; then
        PT_BACKEND="$TMPDIR/testprog-backend.pt"
        run_bsdtrace exec -b "$BACKEND" -p -t 5 -o "$PT_BACKEND" -- "$TESTPROG"
        if [ "$RRC" -eq 0 ] && echo "$ROUT" | grep -q 'instructions'; then
            pass "exec: -b backend"
        else
            fail "exec: -b backend"
        fi

        if echo "$ROUT" | grep -Eq 'MMAP|EXEC'; then
            pass "exec: -p pause on mmap"
        else
            fail "exec: -p pause on mmap"
        fi
    else
        skip "exec: -b backend"
        skip "exec: -p pause on mmap"
    fi

    settle_hwt

    # Max-records
    PT_LIMIT="$TMPDIR/testprog-max.pt"
    run_bsdtrace exec -m 5 -t 5 -o "$PT_LIMIT" -- "$TESTPROG"
    if echo "$ROUT" | grep -q 'max-records:'; then
        pass "exec: -m max-records"
    else
        fail "exec: -m max-records"
    fi

    settle_hwt

    # IP range filter
    if [ -n "$TESTPROG_RANGE" ]; then
        PT_RANGE="$TMPDIR/testprog-range.pt"
        run_bsdtrace exec -r "$TESTPROG_RANGE" -t 5 -o "$PT_RANGE" -- "$TESTPROG"
        RANGE_LINES=$(echo "$ROUT" |
            grep -E '^[[:space:]]+(CALL|RETURN|JUMP|CJMP|SYSCALL)')
        if echo "$RANGE_LINES" |
            grep -Eq 'leaf_add|leaf_mul|nested_outer|nested_inner|branch_test|loop_test|do_write'; then
            if echo "$RANGE_LINES" | grep -Eq 'ld-elf\.so\.1|libc\.so\.7|libsys\.so\.7'; then
                fail "exec: -r range filter"
            else
                pass "exec: -r range filter"
            fi
        else
            fail "exec: -r range filter"
        fi
    else
        skip "exec: -r range filter"
    fi

    settle_hwt

    # Child exit status should propagate through bsdtrace exec.
    run_bsdtrace exec -t 5 -- /bin/sh -c 'exit 7'
    if [ "$RRC" -eq 7 ]; then
        pass "exec: child exit status"
    else
        fail "exec: child exit status"
    fi

    # ── decode (offline) ─────────────────────────────────
    echo "--- decode ---"

    if [ -f "$PT_FILE" ] && [ -f "$META_FILE" ]; then
        # Full decode with .meta
        run_bsdtrace decode -m "$META_FILE" "$PT_FILE"
        DOUT="$ROUT"
        if echo "$DOUT" | grep -q 'instructions'; then
            pass "decode: offline re-decode"
        else
            fail "decode: offline re-decode"
        fi

        # Known functions should appear in offline decode too
        if echo "$DOUT" | grep -q 'leaf_add'; then
            pass "decode: offline has known functions"
        else
            fail "decode: offline has known functions"
        fi

        # JSON format offline
        run_bsdtrace decode -f json -m "$META_FILE" "$PT_FILE"
        if echo "$ROUT" | grep -q '"insn"'; then
            pass "decode: offline json format"
        else
            fail "decode: offline json format"
        fi

        echo "$ROUT" | grep '^{' > "$TMPDIR/decode-json-lines.txt"
        if [ -s "$TMPDIR/decode-json-lines.txt" ] &&
            json_lines_valid "$TMPDIR/decode-json-lines.txt"; then
            pass "decode: json lines valid"
        else
            fail "decode: json lines valid"
        fi

        # Explicit -m meta path
        run_bsdtrace decode -m "$META_FILE" "$PT_FILE"
        if echo "$ROUT" | grep -q 'instructions\|CALL'; then
            pass "decode: explicit -m meta path"
        else
            fail "decode: explicit -m meta path"
        fi

        # Implicit sidecar discovery
        run_bsdtrace decode "$PT_FILE"
        if echo "$ROUT" | grep -q 'instructions\|CALL'; then
            pass "decode: implicit .meta discovery"
        else
            fail "decode: implicit .meta discovery"
        fi
    else
        skip "decode: offline re-decode (no .pt/.meta from exec)"
        skip "decode: offline has known functions"
        skip "decode: offline json format"
        skip "decode: json lines valid"
        skip "decode: explicit -m meta path"
        skip "decode: implicit .meta discovery"
    fi

    settle_hwt

    # ── trace (attach to running process) ────────────────
    echo "--- trace ---"

    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        PT_TRACE="$TMPDIR/trace-attach.pt"
        TRACE_META="$TMPDIR/trace-attach.meta"
        run_bsdtrace trace -d 3 -o "$PT_TRACE" "$STARTED_PID"
        TOUT="$ROUT"
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

        if echo "$TOUT" | grep -Eq 'attach_loop|attach_branch|attach_leaf|attach_exec_mmap'; then
            pass "trace: decoded symbols"
        else
            fail "trace: decoded symbols"
        fi
    else
        fail "trace: could not start background process"
        skip "trace: .pt file created"
        skip "trace: .meta file created"
        skip "trace: decoded symbols"
    fi

    settle_hwt

    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        if [ -n "$BACKEND" ]; then
            run_bsdtrace trace -n -b "$BACKEND" -s 8m -T 0 "$STARTED_PID"
        else
            run_bsdtrace trace -n -s 8m -T 0 "$STARTED_PID"
        fi
        TOUT="$ROUT"
        stop_trace_target

        if [ "$RRC" -eq 0 ] && echo "$TOUT" | grep -qi 'dry-run'; then
            pass "trace: dry run"
            pass "trace: -s 8m"
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

    settle_hwt

    start_trace_target
    if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
        PT_TRACE_JSON="$TMPDIR/trace-json.pt"
        run_bsdtrace trace -f json -m 20 -o "$PT_TRACE_JSON" "$STARTED_PID"
        TOUT="$ROUT"
        stop_trace_target

        if echo "$TOUT" | grep -q '"insn"'; then
            pass "trace: json"
        else
            fail "trace: json"
        fi

        echo "$TOUT" | grep '^{' > "$TMPDIR/trace-json-lines.txt"
        if [ -s "$TMPDIR/trace-json-lines.txt" ] &&
            json_lines_valid "$TMPDIR/trace-json-lines.txt"; then
            pass "trace: json lines valid"
        else
            fail "trace: json lines valid"
        fi

        if echo "$TOUT" | grep -q 'max-records:'; then
            pass "trace: -m max-records"
        else
            fail "trace: -m max-records"
        fi
    else
        fail "trace: could not start background process"
        fail "trace: json"
        fail "trace: json lines valid"
        fail "trace: -m max-records"
    fi

    settle_hwt

    if [ -n "$ATTACHPROG_RANGE" ]; then
        start_trace_target
        if [ -n "$STARTED_PID" ] && kill -0 "$STARTED_PID" 2>/dev/null; then
            PT_TRACE_RANGE="$TMPDIR/trace-range.pt"
            run_bsdtrace trace -p -r "$ATTACHPROG_RANGE" -d 3 -o "$PT_TRACE_RANGE" "$STARTED_PID"
            TOUT="$ROUT"
            stop_trace_target

            TRACE_LINES=$(echo "$TOUT" |
                grep -E '^[[:space:]]+(CALL|RETURN|JUMP|CJMP|SYSCALL)')
            if echo "$TOUT" | grep -q 'MMAP'; then
                pass "trace: -p pause on mmap"
            else
                fail "trace: -p pause on mmap"
            fi

            if echo "$TRACE_LINES" | grep -Eq 'attach_loop|attach_branch|attach_leaf|attach_exec_mmap'; then
                if echo "$TRACE_LINES" | grep -Eq 'ld-elf\.so\.1|libc\.so\.7|libsys\.so\.7'; then
                    fail "trace: -r range filter"
                else
                    pass "trace: -r range filter"
                fi
            else
                fail "trace: -r range filter"
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
