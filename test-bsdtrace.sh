#!/bin/sh
#
# test-bsdtrace.sh — smoke tests for bsdtrace
#
# Run as root (most tests need HWT access):
#   doas sh test-bsdtrace.sh
#

set -e

BIN=".build/x86_64-unknown-freebsd/debug/bsdtrace"
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL  %s\n" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf "  SKIP  %s\n" "$1"; }

cleanup() {
    rm -f /tmp/bsdtrace-test-*.pt /tmp/bsdtrace-test-*.meta
}
trap cleanup EXIT

echo "=== bsdtrace smoke tests ==="
echo ""

# ── Build ──────────────────────────────────────────────
echo "Building..."
swift build 2>&1 | tail -1
echo ""

# ── list ───────────────────────────────────────────────
echo "--- list ---"

if $BIN list 2>&1 | grep -q 'HWT Framework'; then
    pass "list: text output"
else
    fail "list: text output"
fi

if $BIN list -f json 2>&1 | grep -q '"hwt_available"'; then
    pass "list: json output"
else
    fail "list: json output"
fi

# ── info (static ELF) ─────────────────────────────────
echo "--- info ---"

if $BIN info /lib/libc.so.7 2>&1 | grep -q 'Text:'; then
    pass "info: static ELF (libc)"
else
    fail "info: static ELF (libc)"
fi

if $BIN info /libexec/ld-elf.so.1 2>&1 | grep -q 'Functions:'; then
    pass "info: static ELF (ld-elf)"
else
    fail "info: static ELF (ld-elf)"
fi

# ── info (pid) ─────────────────────────────────────────
if [ -d /proc/$$ ]; then
    if $BIN info -p $$ 2>&1 | grep -q 'PID'; then
        pass "info: -p pid (procfs)"
    else
        fail "info: -p pid (procfs)"
    fi
else
    skip "info: -p pid (procfs not mounted)"
fi

# ── exec (requires root + HWT) ────────────────────────
echo "--- exec ---"

if [ "$(id -u)" -ne 0 ]; then
    skip "exec: not root"
    skip "exec: .pt file created"
    skip "exec: .meta file created"
    skip "exec: json output"
    skip "exec: thread selection -T 0"
    skip "decode: offline re-decode"
else
    # Basic exec
    OUT=$($BIN exec -t 2 -o /tmp/bsdtrace-test-basic.pt -- /bin/sleep 0 2>&1)
    if echo "$OUT" | grep -q 'instructions'; then
        pass "exec: basic trace with decode"
    else
        fail "exec: basic trace with decode"
    fi

    # .pt file created
    if [ -f /tmp/bsdtrace-test-basic.pt ] && [ -s /tmp/bsdtrace-test-basic.pt ]; then
        pass "exec: .pt file created"
    else
        fail "exec: .pt file created"
    fi

    # .meta file created (in cwd)
    META=$(ls bsdtrace-*.meta 2>/dev/null | head -1)
    if [ -n "$META" ] && [ -s "$META" ]; then
        pass "exec: .meta file created"
    else
        fail "exec: .meta file created"
    fi

    # JSON output
    JOUT=$($BIN exec -f json -t 2 -o /tmp/bsdtrace-test-json.pt -- /bin/sleep 0 2>&1)
    if echo "$JOUT" | grep -q '"insn"'; then
        pass "exec: json output"
    else
        fail "exec: json output"
    fi

    # Thread selection
    TOUT=$($BIN exec -T 0 -t 2 -o /tmp/bsdtrace-test-tid.pt -- /bin/sleep 0 2>&1)
    if echo "$TOUT" | grep -q 'instructions'; then
        pass "exec: thread selection -T 0"
    else
        fail "exec: thread selection -T 0"
    fi

    # ── decode (offline) ───────────────────────────────
    echo "--- decode ---"

    if [ -n "$META" ]; then
        # Derive .pt path from .meta
        PT_FILE=$(echo "$META" | sed 's/\.meta$/.pt/')
        if [ -f "$PT_FILE" ]; then
            DOUT=$($BIN decode "$PT_FILE" 2>&1)
            if echo "$DOUT" | grep -q 'instructions'; then
                pass "decode: offline re-decode"
            else
                fail "decode: offline re-decode"
            fi
        else
            fail "decode: .pt file not found for offline test"
        fi
    else
        skip "decode: no .meta file from exec"
    fi
fi

# ── Summary ────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
