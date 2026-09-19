#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${1:-"$ROOT/.build/compact-ink"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
xcrun -sdk macosx metal -c "$ROOT/Applications/Shared/InkShaders.metal" -o "$OUT/ink.air"
xcrun -sdk macosx metal -c "$ROOT/Applications/Shared/CompactInk.metal" -o "$OUT/compact.air"
xcrun -sdk macosx metallib "$OUT/ink.air" "$OUT/compact.air" -o "$OUT/ink.metallib"
xcrun swiftc -O -whole-module-optimization "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" \
  "$ROOT/Sources/NotebookCore/InkRenderGeometry.swift" "$ROOT/Applications/Shared/InkRenderUniforms.swift" "$ROOT/Applications/Shared/InkConnectivity.swift" \
  "$ROOT/Applications/TestSupport/CompactInkTestRenderer.swift" "$ROOT/Tests/Performance/CompactInk/main.swift" -o "$OUT/probe"
{
  git -C "$ROOT" rev-parse HEAD
  shasum -a 256 "$ROOT/Sources/NotebookCore/"{InkStrokeGeometry,InkRenderGeometry}.swift \
    "$ROOT/Applications/Shared/"{InkRenderUniforms.swift,InkConnectivity.swift,InkShaders.metal,CompactInk.metal} \
    "$ROOT/Applications/TestSupport/CompactInkTestRenderer.swift" "$ROOT/Tests/Performance/CompactInk/"{main.swift,run.sh}
  xcrun swiftc --version; sw_vers; sysctl -n hw.model hw.memsize machdep.cpu.brand_string
} > "$OUT/environment.txt"
"$OUT/probe" "$OUT/ink.metallib" "$OUT/results.json"
