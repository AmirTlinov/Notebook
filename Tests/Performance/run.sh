#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD=$(mktemp -d /tmp/notebook-camera-pipeline.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.0.0-Beta.5.app/Contents/Developer}
xcrun swiftc -Onone -emit-library -emit-module -module-name NotebookCore \
  -o "$BUILD/libNotebookCore.dylib" -emit-module-path "$BUILD/NotebookCore.swiftmodule" "$ROOT"/Sources/NotebookCore/*.swift
xcrun -sdk macosx metal -c "$ROOT/Applications/Shared/InkShaders.metal" -o "$BUILD/ink.air"
xcrun -sdk macosx metallib "$BUILD/ink.air" -o "$BUILD/default.metallib"
cp "$ROOT/Tests/Performance/CameraPipeline.swift" "$BUILD/main.swift"
xcrun swiftc -Onone -I "$BUILD" -L "$BUILD" -lNotebookCore -Xlinker -rpath -Xlinker "$BUILD" \
  "$ROOT/Applications/Shared/SpatialInkComposer.swift" "$ROOT/Applications/Shared/SpatialInkGeometry.swift" \
  "$ROOT/Applications/Shared/SpatialInkMesh.swift" "$ROOT/Applications/Shared/InkRasterRenderer.swift" \
  "$ROOT/Applications/Shared/GridPaperView.swift" "$ROOT/Applications/Mac/PageVisionRenderer.swift" \
  "$BUILD/main.swift" -o "$BUILD/bench"
"$BUILD/bench" "$@"
