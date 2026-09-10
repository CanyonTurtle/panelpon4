#!/usr/bin/env bash
# Fails if any src/*.zig file exceeds the project's ~500-line-per-file
# guideline (see the doc comments on render_cpu.zig, sim_garbage.zig,
# cpu_engine.zig, etc. for why that guideline exists). Run via `zig build
# lint` or directly.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LIMIT=500
violations=0

for f in src/*.zig; do
  lines=$(wc -l < "$f")
  if [ "$lines" -gt "$LIMIT" ]; then
    echo "  $f: $lines lines (limit $LIMIT)"
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations file(s) over the ${LIMIT}-line guideline"
  exit 1
fi

echo "OK: all src/*.zig files are within the ${LIMIT}-line guideline"
