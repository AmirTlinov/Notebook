#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# Development clients explicitly select an existing isolated owner. Production
# startup belongs to the signed runtime launcher.
: "${NOTEBOOK_SOCKET:?Set NOTEBOOK_SOCKET to the private development runtime socket}"
exec "$ROOT/node_modules/.bin/tsx" "$ROOT/src/index.ts"
