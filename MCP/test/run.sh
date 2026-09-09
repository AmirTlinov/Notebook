#!/bin/sh
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${NOTEBOOK_IPC_TEST_HOST:-}" ]; then
  swift build --package-path "$ROOT/.." --product notebook-ipc-test-host >&2
  NOTEBOOK_IPC_TEST_HOST="$(swift build --package-path "$ROOT/.." --show-bin-path)/notebook-ipc-test-host"
  export NOTEBOOK_IPC_TEST_HOST
fi
case "${1:-test}" in
  test) exec "$ROOT/node_modules/.bin/tsx" --test "$ROOT"/test/*.test.ts ;;
  smoke) exec "$ROOT/node_modules/.bin/tsx" "$ROOT/test/smoke.ts" ;;
  *) echo "Usage: $0 [test|smoke]" >&2; exit 2 ;;
esac
