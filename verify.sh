#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/notebook-derived.XXXXXX")
SIMULATOR_ID=""
SHUTDOWN_SIMULATOR=false

cleanup() {
  if [[ "$SHUTDOWN_SIMULATOR" == true && -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$DERIVED"
}
trap cleanup EXIT

cd "$ROOT"
swift test

if rg -n 'PKCanvasView|override func draw\(' \
  "$ROOT/Applications/iPad" \
  --glob '*.swift'; then
  printf '%s\n' \
    'iPad должен иметь один визуальный тракт чернил: InkCanvasView.' >&2
  exit 1
fi
if [[ "$(rg -l ': MTKView' "$ROOT/Applications/iPad" --glob '*.swift' | wc -l | tr -d ' ')" != 1 ]]; then
  printf '%s\n' \
    'На iPad должен быть ровно один Metal-владелец видимых чернил.' >&2
  exit 1
fi
ERASER_MUTATION_COUNT=$(
  { rg -o 'erasingPath\(' \
      "$ROOT/Applications/iPad/PencilCanvasView.swift" || true; } \
    | wc -l \
    | tr -d ' '
)
if [[ "$ERASER_MUTATION_COUNT" != 1 ]]; then
  printf '%s\n' \
    'PencilKit должен вычислять ластик один раз после завершения жеста.' >&2
  exit 1
fi

ERASER_APP="$DERIVED/NotebookEraserProof.app"
mkdir -p "$ERASER_APP/Contents/MacOS"
xcrun swiftc \
  "$ROOT/Tests/PencilKitIntegration/EraserPathProof.swift" \
  -o "$ERASER_APP/Contents/MacOS/NotebookEraserProof"
plutil -create xml1 "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier \
  -string com.amirtlinov.notebook.eraser-proof \
  "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundleExecutable \
  -string NotebookEraserProof \
  "$ERASER_APP/Contents/Info.plist"
plutil -insert CFBundlePackageType \
  -string APPL \
  "$ERASER_APP/Contents/Info.plist"
"$ERASER_APP/Contents/MacOS/NotebookEraserProof"

cd "$ROOT/MCP"
npm ci --ignore-scripts
npm run check
npm test
npm run smoke

cd "$ROOT/Applications"
xcodegen generate --spec project.yml
xcodebuild \
  -quiet \
  -project Notebook.xcodeproj \
  -scheme NotebookMac \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED/mac" \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -quiet \
  -project Notebook.xcodeproj \
  -scheme Notebook \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED/ipad" \
  CODE_SIGNING_ALLOWED=NO \
  build

read -r SIMULATOR_ID SIMULATOR_STATE <<<"$(
  xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [
    device
    for runtime in data["devices"].values()
    for device in runtime
    if device.get("isAvailable") and device["name"].startswith("iPad")
]
if not devices:
    raise SystemExit("Нужен установленный iPad Simulator")
devices.sort(key=lambda d: (
    d["state"] != "Booted",
    "11-inch" not in d["name"],
    d["name"],
))
chosen = devices[0]
print(chosen["udid"], chosen["state"])
'
)"

if [[ "$SIMULATOR_STATE" != Booted ]]; then
  xcrun simctl boot "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
  SHUTDOWN_SIMULATOR=true
fi

xcodebuild \
  -quiet \
  -project Notebook.xcodeproj \
  -scheme Notebook \
  -configuration Debug \
  -collect-test-diagnostics never \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED/ipad-tests" \
  test \
  -only-testing:NotebookTests \
  -only-testing:NotebookUITests/DrawingResponsivenessTests

APP_CONTAINER=$(xcrun simctl get_app_container \
  "$SIMULATOR_ID" com.amirtlinov.notebook data)
python3 - "$APP_CONTAINER/tmp/NotebookUITests/DrawingResponsiveness/pages" <<'PY'
import json
import pathlib
import sys

pages = list(pathlib.Path(sys.argv[1]).glob("*.json"))
if len(pages) != 1:
    raise SystemExit(f"Ожидался один проверочный лист, найдено: {len(pages)}")
page = json.loads(pages[0].read_text())
counter = page["drawingStamp"]["counter"]
if counter != 1:
    raise SystemExit(f"Одно движение должно сохраниться один раз, получено: {counter}")
PY

printf '\nNotebook проверен: Swift, локальные инструменты, MCP, macOS, iPadOS и отзывчивость Simulator прошли.\n'
