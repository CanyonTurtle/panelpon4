#!/usr/bin/env bash
# Fails if any src/*.zig file has a comment block (consecutive full-line `//`
# comments) longer than 2 lines. Run via `zig build lint` or directly.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LIMIT=2
violations=0

for f in src/*.zig; do
  awk -v file="$f" -v limit="$LIMIT" '
    function flush() {
      if (len > limit) {
        printf "  %s:%d-%d: %d-line comment (limit %d)\n", file, start, start + len - 1, len, limit
        violation_count++
      }
      len = 0
    }
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      if (substr(line, 1, 2) == "//") {
        if (len == 0) start = NR
        len++
      } else {
        flush()
      }
    }
    END {
      flush()
      exit violation_count > 0 ? 1 : 0
    }
  ' "$f" || violations=$((violations + 1))
done

if [ "$violations" -gt 0 ]; then
  echo "FAIL: comment blocks over the ${LIMIT}-line limit found above"
  exit 1
fi

echo "OK: all src/*.zig comment blocks are within the ${LIMIT}-line limit"
