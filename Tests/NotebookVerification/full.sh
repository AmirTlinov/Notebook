#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/../.." && pwd)
ARGS=(--full)
if [[ -n "${NOTEBOOK_VERIFY_EVIDENCE_DIR:-}" ]]; then
  ARGS+=(--evidence-dir "$NOTEBOOK_VERIFY_EVIDENCE_DIR")
fi
exec python3 -B "$ROOT/Applications/notebook_verification.py" "${ARGS[@]}" "$@"
