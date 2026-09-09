#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD="$ROOT/.build/agent-executor-contract"
mkdir -p "$BUILD"
# This isolated module contains the real JSONValue, not a second persistence writer.
xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name NotebookCore \
  "$ROOT/Sources/NotebookCore/JSONValue.swift" -emit-module-path "$BUILD/NotebookCore.swiftmodule" \
  -o "$BUILD/libNotebookCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -D NOTEBOOK_AGENT_CONTRACT_TEST \
  -I "$BUILD" -L "$BUILD" -lNotebookCore -Xlinker -rpath -Xlinker "$BUILD" \
  "$ROOT/Applications/Mac/NotebookAgentRuntimeProfile.swift" \
  "$ROOT/Applications/Mac/NotebookAgentProcess.swift" \
  "$ROOT/Applications/Mac/NotebookAgentToolResult.swift" \
  "$ROOT/Applications/Mac/NotebookAgentExecutor.swift" \
  "$ROOT/Tests/NotebookAgentExecutorHarness/main.swift" -o "$BUILD/notebook-agent-executor-harness"
node "$ROOT/Tests/NotebookAgentExecutorHarness/provider-contract.mjs" "$BUILD/notebook-agent-executor-harness" "$ROOT"
