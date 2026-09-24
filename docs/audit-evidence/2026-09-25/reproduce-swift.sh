#!/usr/bin/env bash
# Historical audit probes, not acceptance tests. No live application or store.
set -euo pipefail
repo="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo"
evidence="$repo/docs/audit-evidence/2026-09-25"
out="$(mktemp -d "${TMPDIR:-/tmp}/notebook-audit-swift.XXXXXX")"
export NOTEBOOK_HOME="$out/isolated-home"
mkdir -p "$out/module-cache"

swiftc -O -whole-module-optimization -module-name NotebookCore \
  -emit-library -emit-module -enable-testing \
  -I Sources/CSQLite -module-cache-path "$out/module-cache" \
  Sources/NotebookCore/*.swift -o "$out/libNotebookCore.dylib" \
  -emit-module-path "$out/NotebookCore.swiftmodule"

link=(-O -I "$out" -I Sources/CSQLite -L "$out" -lNotebookCore \
  -module-cache-path "$out/module-cache" -Xlinker -rpath -Xlinker "$out")
for probe in core file-upload; do
  swiftc "${link[@]}" "$evidence/$probe.swift" -o "$out/$probe"
  "$out/$probe" | tee "$out/$probe-result.txt"
done

swiftc "${link[@]}" -whole-module-optimization -parse-as-library \
  -emit-library -emit-module -module-name NotebookCodex \
  Sources/NotebookCodex/*.swift -o "$out/libNotebookCodex.dylib" \
  -emit-module-path "$out/NotebookCodex.swiftmodule"
swiftc "${link[@]}" -parse-as-library -lNotebookCodex \
  Applications/Shared/NotebookPersistenceQueue.swift \
  Applications/Mac/NotebookCodexSidecar.swift \
  Applications/Mac/MacNotebookProjectFiles.swift \
  Applications/Mac/MacNotebookProjectRuns.swift \
  Applications/Mac/MacNotebookVoice.swift \
  Applications/Mac/MacNotebookDictation.swift \
  "$evidence/sidecar.swift" -o "$out/sidecar"
"$out/sidecar" | tee "$out/sidecar-result.txt"

swiftc -O -module-cache-path "$out/module-cache" "$evidence/lasso.swift" -o "$out/lasso"
"$out/lasso" | tee "$out/lasso-result.txt"
swiftc -O -parse-as-library -module-cache-path "$out/module-cache" \
  "$evidence/markup-queue.swift" -o "$out/markup-queue"
"$out/markup-queue" | tee "$out/markup-queue-result.txt"
printf 'Temporary build and outputs: %s\n' "$out"
