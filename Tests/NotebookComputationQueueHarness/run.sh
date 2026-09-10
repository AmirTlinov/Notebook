#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
swift build >&2
BUILD=$(swift build --show-bin-path)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/notebook-computation-queue.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -I "$BUILD" -I "$ROOT/Sources/CSQLite" -L "$BUILD" -lNotebookCore \
  "$ROOT/Applications/Shared/NotebookPersistenceQueue.swift" \
  "$ROOT/Tests/NotebookComputationQueueHarness/main.swift" -o "$TEMP/proof"
"$TEMP/proof"
