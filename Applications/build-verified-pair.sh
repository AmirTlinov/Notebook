#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/Applications/notebook_release.py" build-pair --source-root "$ROOT" "$@"
