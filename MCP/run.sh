#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# The native Mac model owns file observation and the NearbySync listener. Wake
# that owner for the real store before accepting an MCP mutation. Test stores
# set NOTEBOOK_HOME and remain completely isolated.
if [ -z "${NOTEBOOK_HOME:-}" ] && [ "$(uname -s)" = Darwin ]; then
  INSTALLED_APP="$HOME/Applications/Notebook.app"
  if [ -d "$INSTALLED_APP" ]; then
    open -gj "$INSTALLED_APP" >/dev/null 2>&1 || true
  else
    open -gj -b com.amirtlinov.notebook.mac >/dev/null 2>&1 || true
  fi
fi

swift build --package-path "$ROOT/.." --product notebook-bridge >&2
NOTEBOOK_BRIDGE="$(swift build --package-path "$ROOT/.." --show-bin-path)/notebook-bridge"
export NOTEBOOK_BRIDGE
exec "$ROOT/node_modules/.bin/tsx" "$ROOT/src/index.ts"
