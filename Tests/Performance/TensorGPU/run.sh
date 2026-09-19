#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${1:-"$ROOT/.build/tensor-gpu"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
xcrun -sdk macosx metal -fno-fast-math -c "$ROOT/Applications/Shared/InkShaders.metal" -o "$OUT/baseline.air"
xcrun -sdk macosx metal -fno-fast-math -c "$ROOT/Tests/Performance/TensorGPU/TensorInk.metal" -o "$OUT/direct.air"
xcrun -sdk macosx metallib "$OUT/baseline.air" "$OUT/direct.air" -o "$OUT/ink.metallib"
xcrun swiftc -O -whole-module-optimization "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" \
  "$ROOT/Tests/Performance/TensorGPU/main.swift" -o "$OUT/probe"
{
  git -C "$ROOT" rev-parse HEAD
  shasum -a 256 "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" "$ROOT/Applications/Shared/InkShaders.metal" \
    "$ROOT/Tests/Performance/TensorGPU/"{TensorInk.metal,main.swift,run.sh} \
    "$ROOT/Tests/NotebookCoreTests/Resources/QuickShapeMeasured.json"
  xcrun swiftc --version; xcrun -sdk macosx metal --version; sw_vers
  sysctl -n hw.model hw.memsize machdep.cpu.brand_string
} > "$OUT/environment.txt"
"$OUT/probe" "$OUT/ink.metallib" "$ROOT/Tests/NotebookCoreTests/Resources/QuickShapeMeasured.json" "$OUT"
