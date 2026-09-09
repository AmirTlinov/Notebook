#!/bin/bash
# Compile the production metadata owner without mounting UIKit, WebKit, or user data.
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/.build/workspace-scale-baseline/indexed"}
mkdir -p "$OUT"
cd "$ROOT"
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
root, out = map(Path, sys.argv[1:])
baseline = subprocess.check_output(['git', 'show', '231917a:Applications/Shared/SpatialWorkspaceView.swift'], text=True)
current = (root / 'Applications/Shared/WorkspaceSceneContent.swift').read_text()
start = baseline.index('enum WorkspaceSceneProjection {')
end = baseline.index('\n#if os(macOS)', start)
old_projection = baseline[start:end].replace('WorkspaceSceneProjection', 'BaselineSceneProjection')
item_start = current.index('struct RenderedWorkspaceItem:')
item_end = current.index('\nenum WorkspaceSceneProjection {', item_start)
material = (root / 'Applications/Shared/WorkspaceCoverMaterial.swift').read_text()
padding = next(row.strip().replace('nonisolated ', '') for row in material.splitlines() if 'static let shadowPadding =' in row)
(out / 'ProjectionSupport.swift').write_text('import Foundation\nimport NotebookCore\n\nenum WorkspaceCoverRaster { ' + padding + ' }\n\n' + current[item_start:item_end] + '\n\n' + old_projection)
manifest = {
  'baseline_commit': '231917a',
  'current_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
  'baseline_source_sha256': hashlib.sha256(baseline.encode()).hexdigest(),
  'current_projection_sha256': hashlib.sha256(current.encode()).hexdigest(),
  'prepared_index_sha256': hashlib.sha256((root / 'Applications/Shared/WorkspaceSceneIndex.swift').read_bytes()).hexdigest(),
  'core_index_sha256': hashlib.sha256((root / 'Sources/NotebookCore/WorkspaceSpatialIndex.swift').read_bytes()).hexdigest(),
  'workspace_catalog_sha256': hashlib.sha256((root / 'Sources/NotebookCore/WorkspaceIndex.swift').read_bytes()).hexdigest(),
  'extraction': 'Baseline projection body from git, enum renamed only. Current RenderedWorkspaceItem unchanged. Production shadowPadding constant replaces its UI owner.',
  'scope': 'Native Release CPU metadata only; synthetic fixtures; not physical iPad frame time, rendering, WebKit, loading or memory acceptance.'
}
(out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
swift build -c release --scratch-path "$OUT/swift" --target NotebookCore > "$OUT/build.log" 2>&1
PRODUCTS=$(swift build -c release --scratch-path "$OUT/swift" --show-bin-path)
xcrun swiftc -O -target "$(uname -m)-apple-macosx27.0" -I "$PRODUCTS" \
  "$OUT/ProjectionSupport.swift" "$ROOT/Applications/Shared/WorkspaceSceneIndex.swift" \
  "$ROOT/Applications/WorkspaceScaleProbe/main.swift" "$PRODUCTS/NotebookCore.o" -o "$OUT/probe"
"$OUT/probe" "$OUT/results.json" | tee "$OUT/run.log"
system_profiler SPHardwareDataType > "$OUT/hardware.txt"
swift --version > "$OUT/toolchain.txt"
