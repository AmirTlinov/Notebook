#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo 'Usage: generate-load-fixture.sh <NEW directory> [count: 100000] [seed: 410041]' >&2
  exit 1
fi
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/notebook-fixture.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
SOURCE="$ROOT/LoadFixtures/main.swift"
HASH=$(shasum -a 256 "$SOURCE" | awk '{print $1}')
xcrun swiftc -O "$SOURCE" -o "$BUILD/generate"
"$BUILD/generate" "$1" "${2:-100000}" "${3:-410041}" "$HASH"
python3 "$ROOT/LoadFixtures/verify.py" "$1"
