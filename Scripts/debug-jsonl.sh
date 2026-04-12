#!/bin/sh
#
# debug-jsonl.sh — diagnose why dtlm's JSON-format pipe path is
# producing no output. Runs `dtlm watch sched-on-cpu --format json
# --duration 1` with the structured-backend stderr trace enabled,
# captures stdout (JSON records) and stderr (debug trace) into
# separate files, and prints a digest.
#
# Usage:  sudo ./Scripts/debug-jsonl.sh

set -eu

BIN="${BIN:-.build-dev3/x86_64-unknown-freebsd/debug/dtlm}"
STDOUT_LOG=/tmp/dtlm-stdout.log
STDERR_LOG=/tmp/dtlm-stderr.log

if [ ! -x "$BIN" ]; then
	echo "error: dtlm binary not found at $BIN" >&2
	echo "       run \`swift build --build-path .build-dev2\` first" >&2
	exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "error: must run as root (libdtrace requires it)" >&2
	echo "       run as: sudo $0" >&2
	exit 1
fi

# Wipe previous logs so we don't read stale data.
: > "$STDOUT_LOG"
: > "$STDERR_LOG"

# `env DTLM_STRUCTURED_DEBUG=1` sets the env var for the dtlm
# child process (sudo on its own would eat the assignment).
env DTLM_STRUCTURED_DEBUG=1 \
	"$BIN" watch sched-on-cpu --format json --duration 1 \
	> "$STDOUT_LOG" 2> "$STDERR_LOG" \
	|| echo "dtlm exited with non-zero status $?"

echo
echo "=== stdout (should be JSON records) ==="
wc -l "$STDOUT_LOG"
echo "--- first 5 lines:"
head -5 "$STDOUT_LOG"
echo
echo "=== stderr (should have [dtlm-debug] lines) ==="
wc -l "$STDERR_LOG"
echo "--- full contents:"
cat "$STDERR_LOG"
