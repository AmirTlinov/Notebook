#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${1:-"$ROOT/.build/tensor-tiles"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
xcrun -sdk macosx metal -fno-fast-math -c "$ROOT/Applications/Shared/InkShaders.metal" -o "$OUT/baseline.air"
xcrun -sdk macosx metal -fno-fast-math -c "$ROOT/Tests/Performance/TensorGPU/TensorInk.metal" -o "$OUT/direct.air"
xcrun -sdk macosx metallib "$OUT/baseline.air" "$OUT/direct.air" -o "$OUT/ink.metallib"
xcrun swiftc -O -whole-module-optimization "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" \
  "$ROOT/Tests/Performance/TensorGPU/Support.swift" \
  "$ROOT/Tests/Performance/TensorTiles/TileIndex.swift" \
  "$ROOT/Tests/Performance/TensorTiles/main.swift" -o "$OUT/probe"
{
  git -C "$ROOT" rev-parse HEAD
  shasum -a 256 "$ROOT/Sources/NotebookCore/InkStrokeGeometry.swift" "$ROOT/Applications/Shared/InkShaders.metal" \
    "$ROOT/Tests/Performance/TensorGPU/"{TensorInk.metal,Support.swift} \
    "$ROOT/Tests/Performance/TensorTiles/"{TileIndex.swift,main.swift,run.sh}
  xcrun swiftc --version; xcrun -sdk macosx metal --version; sw_vers
  sysctl -n hw.model hw.memsize machdep.cpu.brand_string
} > "$OUT/environment.txt"
"$OUT/probe" "$OUT/ink.metallib" unused "$OUT"
