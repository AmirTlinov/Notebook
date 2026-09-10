#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD="$ROOT/.build/computation-contract"
mkdir -p "$BUILD"
python3 "$ROOT/Tests/NotebookComputationHarness/verify-resources.py"
FINGERPRINT=$(python3 "$ROOT/Tests/NotebookComputationHarness/verify-resources.py" --fingerprint)
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Tests/NotebookComputationHarness/main.swift" \
  -o "$BUILD/notebook-computation-probe"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BUILD/notebook-computation-probe" \
  "$ROOT/Applications/ComputationResources" \
  "$ROOT/Tests/NotebookComputationHarness" \
  "$BUILD/result.json"
test "$FINGERPRINT" = "$(python3 "$ROOT/Tests/NotebookComputationHarness/verify-resources.py" --fingerprint)"
python3 - "$BUILD/result.json" "$FINGERPRINT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text())
report["sourceFingerprint"] = sys.argv[2]
report["osNetworkPolicy"] = "deny network*"
path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
PY
