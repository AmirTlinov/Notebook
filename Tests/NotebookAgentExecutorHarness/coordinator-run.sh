#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD="$ROOT/.build/agent-coordinator-contract"
CORE="${NOTEBOOK_CORE_PRODUCTS:-$ROOT/.build/out/Products/Debug}"
test -f "$CORE/NotebookCore.o" || { echo 'Build the real NotebookCore product first; no fake store fallback.' >&2; exit 1; }
mkdir -p "$BUILD"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -D NOTEBOOK_AGENT_CONTRACT_TEST \
  -I "$CORE" -I "$ROOT/Sources/CSQLite" "$CORE/NotebookCore.o" -lsqlite3 \
  "$ROOT/Applications/Mac/NotebookAgentRuntimeProfile.swift" \
  "$ROOT/Applications/Mac/NotebookAgentProcess.swift" \
  "$ROOT/Applications/Mac/NotebookAgentToolResult.swift" \
  "$ROOT/Applications/Mac/NotebookAgentExecutor.swift" \
  "$ROOT/Applications/Mac/NotebookAgentCoordinator.swift" \
  "$ROOT/Applications/Shared/NotebookPersistenceQueue.swift" \
  "$ROOT/Tests/NotebookAgentExecutorHarness/coordinator-main.swift" -o "$BUILD/notebook-agent-coordinator-harness"
node "$ROOT/Tests/NotebookAgentExecutorHarness/coordinator-contract.mjs" "$BUILD/notebook-agent-coordinator-harness" "$ROOT"
