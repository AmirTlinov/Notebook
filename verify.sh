#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/tetrad-derived.XXXXXX")
trap 'rm -rf "$DERIVED"' EXIT

cd "$ROOT"
swift test

ERASER_APP="$DERIVED/TetradEraserProof.app"
mkdir -p "$ERASER_APP/Contents/MacOS"
xcrun swiftc \
  "$ROOT/Tests/PencilKitIntegration/EraserPathProof.swift" \
  -o "$ERASER_APP/Contents/MacOS/TetradEraserProof"
plutil -create xml1 "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier \
  -string com.amirtlinov.tetrad.eraser-proof \
  "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundleExecutable \
  -string TetradEraserProof \
  "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundlePackageType \
  -string APPL \
  "$ERASER_APP/Contents/Info.plist"
"$ERASER_APP/Contents/MacOS/TetradEraserProof"

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

printf '\nТетрадь проверена: Swift, локальный ластик, MCP, macOS и iPadOS прошли.\n'
