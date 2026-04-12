#!/bin/sh
#
# fix-profile-newlines.sh — append "\n" to the format string of every
# printf() call in Sources/dtlm/Profiles/*.d that isn't already
# newline-terminated. Required for the structured (--format json)
# backend, whose reader splits the libdtrace pipe stream on 0x0A.
#
# Usage:  ./Scripts/fix-profile-newlines.sh
#
# Idempotent — running it twice is safe.

set -eu

PROFILE_DIR="Sources/dtlm/Profiles"

if [ ! -d "$PROFILE_DIR" ]; then
	echo "error: $PROFILE_DIR not found (run from repo root)" >&2
	exit 1
fi

fixed=0
for f in "$PROFILE_DIR"/*.d; do
	# awk pass: on every line containing `printf("...`, find the
	# closing `"` of the format string (the FIRST `"` after `printf("`)
	# and insert `\n` before it — but only if the format string
	# doesn't already end with \n.
	awk '
	{
		line = $0
		# Look for `printf("` — capture position of opening quote.
		p = index(line, "printf(\"")
		if (p == 0) {
			print line
			next
		}
		# Skip to start of format-string body (just after printf(").
		startBody = p + 8
		# Walk forward to find the matching closing quote, honoring \"
		# escapes inside the format string.
		i = startBody
		L = length(line)
		while (i <= L) {
			c = substr(line, i, 1)
			if (c == "\\") { i += 2; continue }
			if (c == "\"") break
			i++
		}
		if (i > L) {
			print line
			next
		}
		# i now points at the closing quote of the format string.
		# Check whether the two chars before it are already \n.
		tail2 = substr(line, i - 2, 2)
		if (tail2 == "\\n") {
			print line
			next
		}
		# Insert \n just before the closing quote.
		newline = substr(line, 1, i - 1) "\\n" substr(line, i)
		print newline
	}
	' "$f" > "$f.tmp"

	if ! cmp -s "$f" "$f.tmp"; then
		mv "$f.tmp" "$f"
		fixed=$((fixed + 1))
		echo "  fixed $f"
	else
		rm -f "$f.tmp"
	fi
done

echo
echo "Done. $fixed profile(s) updated."
