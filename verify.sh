#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/tetrad-derived.XXXXXX")
trap 'rm -rf "$DERIVED"' EXIT

cd "$ROOT"
swift test

cd "$ROOT/MCP"
npm ci --ignore-scripts
npm run check
npm test
npm run smoke

cd "$ROOT/Applications"
xcodegen generate --spec project.yml
xcodebuild \
  -quiet \
  -project Tetrad.xcodeproj \
  -scheme TetradMac \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED/mac" \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -quiet \
  -project Tetrad.xcodeproj \
  -scheme Tetrad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED/ipad" \
  CODE_SIGNING_ALLOWED=NO \
  build

printf '\nТетрадь проверена: Swift, MCP, macOS и iPadOS прошли.\n'
