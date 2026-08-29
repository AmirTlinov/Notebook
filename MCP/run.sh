#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
exec "$ROOT/node_modules/.bin/tsx" "$ROOT/src/index.ts"
