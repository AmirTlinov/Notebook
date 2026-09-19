#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${1:-"$ROOT/.build/relational-ink"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
xcrun swiftc -O -whole-module-optimization \
  "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" \
  "$ROOT/Tests/Performance/RelationalInk/Codec.swift" \
  "$ROOT/Tests/Performance/RelationalInk/main.swift" -o "$OUT/probe"
{
  git -C "$ROOT" rev-parse HEAD
  shasum -a 256 "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" \
    "$ROOT/Tests/Performance/RelationalInk/"{Codec.swift,main.swift,run.sh} \
    "$ROOT/Tests/NotebookCoreTests/Resources/QuickShapeMeasured.json"
  xcrun swiftc --version
  sw_vers
  sysctl -n hw.model hw.memsize machdep.cpu.brand_string
} > "$OUT/environment.txt"
"$OUT/probe" "$ROOT/Tests/NotebookCoreTests/Resources/QuickShapeMeasured.json" "$OUT"
echo "Results: $OUT/results.json"
