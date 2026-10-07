#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# Development clients explicitly select an existing isolated owner. Production
# startup belongs to the runtime packaged with the Codex plugin.
: "${NOTEBOOK_SOCKET:?Set NOTEBOOK_SOCKET to the private development runtime socket}"
/usr/bin/env node "$ROOT/build-panel.mjs" >&2
exec "$ROOT/node_modules/.bin/tsx" "$ROOT/src/index.ts"
