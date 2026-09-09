#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# The installed menu-bar helper is the only production store/transport owner.
# Tests provide a private socket served by the separate isolated test host.
if [ -z "${NOTEBOOK_SOCKET:-}" ] && [ "$(uname -s)" = Darwin ]; then
  INSTALLED_APP="$HOME/Applications/Notebook.app"
  if [ -d "$INSTALLED_APP" ]; then
    open -gj "$INSTALLED_APP" >/dev/null 2>&1 || true
  else
    open -gj -b com.amirtlinov.notebook.mac >/dev/null 2>&1 || true
  fi
fi
exec "$ROOT/node_modules/.bin/tsx" "$ROOT/src/index.ts"
