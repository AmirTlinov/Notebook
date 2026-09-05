#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/notebook-derived.XXXXXX")
SIMULATOR_ID=""
SHUTDOWN_SIMULATOR=false
MAC_SMOKE_PID=""

cleanup() {
  if [[ -n "$MAC_SMOKE_PID" ]]; then
    kill "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
    wait "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$SHUTDOWN_SIMULATOR" == true && -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$DERIVED"
}
trap cleanup EXIT

cd "$ROOT"
swift test

ICON_PROOF="$DERIVED/AppIcon.appiconset"
"$ROOT/Applications/render-app-icon.sh" "$ICON_PROOF"
for icon in "$ROOT"/Applications/Assets.xcassets/AppIcon.appiconset/*.png; do
  if ! cmp -s "$icon" "$ICON_PROOF/$(basename "$icon")"; then
    printf '%s\n' \
      'Иконки Mac и iPad должны быть свежим результатом одного AppIcon.svg.' >&2
    exit 1
  fi
done

if rg -n 'DirectoryWatcher' "$ROOT/Applications/Mac/MacRootView.swift" \
  || ! rg -q 'externalChangeWatcher: DirectoryWatcher' \
    "$ROOT/Applications/Shared/NotebookAppModel.swift"; then
  printf '%s\n' \
    'MCP file-watch должен принадлежать модели Mac, а не времени жизни окна.' >&2
  exit 1
fi

if rg -n 'PKCanvasView|override func draw\(' \
  "$ROOT/Applications/iPad" \
  --glob '*.swift'; then
  printf '%s\n' \
    'iPad должен иметь один визуальный тракт чернил: InkCanvasView.' >&2
  exit 1
fi
if [[ "$(rg -l ': MTKView' "$ROOT/Applications/iPad" --glob '*.swift' | wc -l | tr -d ' ')" != 1 ]]; then
  printf '%s\n' \
    'На iPad должна быть одна реализация Metal-рендера: InkCanvasView.' >&2
  exit 1
fi
if ! rg -q 'struct SpatialInkSurfaceView: UIViewRepresentable' \
  "$ROOT/Applications/Shared/SpatialInkSurfaceView.swift" \
  || ! rg -q 'makeUIView\(context: Context\) -> InkCanvasView' \
    "$ROOT/Applications/Shared/SpatialInkSurfaceView.swift"; then
  printf '%s\n' \
    'Каждая обложка должна носить собственный InkCanvasView внутри своего transform.' >&2
  exit 1
fi
if rg -n 'SpatialInkTransitionView|drawing\.image\(' \
  "$ROOT/Applications/Shared/SpatialInkSurfaceView.swift"; then
  printf '%s\n' \
    'Обложка должна двигать живой Metal-холст, а не запаздывающий снимок.' >&2
  exit 1
fi
if rg -n 'SpatialInkDrawingComposer' \
  "$ROOT/Applications/iPad/SpatialInkCanvas.swift"; then
  printf '%s\n' \
    'Пространственный Metal должен повторять сырые точки журнала без перерисовки PencilKit.' >&2
  exit 1
fi
if rg -n 'erasingPath\(|PKDrawing\(' "$ROOT/Applications/iPad/PencilCanvasView.swift"; then
  printf '%s\n' 'Новые действия пера сохраняют точки общей геометрии.' >&2
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
for pair in \
  "node_modules/marked/lib/marked.umd.js:$ROOT/Applications/WebResources/marked.umd.js" \
  "node_modules/dompurify/dist/purify.min.js:$ROOT/Applications/WebResources/purify.min.js" \
  "node_modules/mathjax/a11y/assistive-mml.js:$ROOT/Applications/WebResources/a11y/assistive-mml.js" \
  "node_modules/@mathjax/mathjax-newcm-font/svg.js:$ROOT/Applications/WebResources/fonts/mathjax-newcm-font/svg.js" \
  "node_modules/mathjax/tex-svg-nofont.js:$ROOT/Applications/WebResources/tex-svg-nofont.js" \
  "node_modules/marked/LICENSE:$ROOT/Applications/WebResources/Licenses/marked-LICENSE" \
  "node_modules/dompurify/LICENSE:$ROOT/Applications/WebResources/Licenses/dompurify-LICENSE" \
  "node_modules/dompurify/LICENSE-MPL:$ROOT/Applications/WebResources/Licenses/dompurify-LICENSE-MPL" \
  "node_modules/mathjax/LICENSE:$ROOT/Applications/WebResources/Licenses/mathjax-LICENSE"
do
  source=${pair%%:*}
  bundled=${pair#*:}
  if ! cmp -s "$source" "$bundled"; then
    printf '%s\n' \
      "WebKit runtime должен совпадать с зафиксированным npm-пакетом: $source" >&2
    exit 1
  fi
done
diff -qr node_modules/@mathjax/mathjax-newcm-font/svg \
  "$ROOT/Applications/WebResources/fonts/mathjax-newcm-font/svg"
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
MAC_SMOKE_APP="$DERIVED/mac/Build/Products/Debug/Notebook.app"
MAC_SMOKE_LOG="$DERIVED/mac-document-launch.log"
"$MAC_SMOKE_APP/Contents/MacOS/Notebook" \
  --notebook-mac-document-launch-fixture \
  >"$MAC_SMOKE_LOG" 2>&1 &
MAC_SMOKE_PID=$!
sleep 5
if ! kill -0 "$MAC_SMOKE_PID" >/dev/null 2>&1; then
  cat "$MAC_SMOKE_LOG" >&2
  printf '%s\n' \
    'Mac должен открыть живой многостраничный WebKit-документ.' >&2
  exit 1
fi
kill "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
wait "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
MAC_SMOKE_PID=""
xcodebuild \
  -quiet \
  -project Notebook.xcodeproj \
  -scheme NotebookMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED/mac-tests" \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:NotebookMacTests
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
