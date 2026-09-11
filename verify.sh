#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
exec python3 -B "$ROOT/Applications/notebook_verification.py" "$@"
