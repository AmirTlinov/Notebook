#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/notebook-derived.XXXXXX")
EVIDENCE=${NOTEBOOK_VERIFY_EVIDENCE_DIR:-"$DERIVED/evidence"}
mkdir -p "$EVIDENCE"
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
"$ROOT/Applications/test-load-fixture.sh"

ICON_PROOF="$DERIVED/AppIcon.appiconset"
"$ROOT/Applications/render-app-icon.sh" "$ICON_PROOF"
for icon in "$ROOT"/Applications/Assets.xcassets/AppIcon.appiconset/*.png; do
  if ! cmp -s "$icon" "$ICON_PROOF/$(basename "$icon")"; then
    printf '%s\n' \
      'Иконки Mac и iPad должны быть свежим результатом одного AppIcon.svg.' >&2
    exit 1
  fi
done

if rg -n 'WindowGroup|MacRootView|MacPageTurnView' "$ROOT/Applications/Mac" --glob '*.swift' \
  || ! rg -q 'MenuBarExtra' "$ROOT/Applications/Mac/NotebookMacApp.swift"; then
  printf '%s\n' 'Mac должен работать из строки меню без рабочего окна и второго перелистывания.' >&2
  exit 1
fi

if rg -n 'PKCanvasView|override func draw\(' \
  "$ROOT/Applications/iPad" \
  --glob '*.swift'; then
  printf '%s\n' \
    'iPad должен иметь один визуальный тракт чернил: InkCanvasView.' >&2
  exit 1
fi
if [[ "$(rg -l ': MTKView' "$ROOT/Applications/Shared/InkCanvasView.swift" --glob '*.swift' | wc -l | tr -d ' ')" != 1 ]]; then
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
MAC_SMOKE_PROOF="$EVIDENCE/mac-helper-launch.json"
NOTEBOOK_MAC_LAUNCH_PROOF="$MAC_SMOKE_PROOF" \
"$MAC_SMOKE_APP/Contents/MacOS/Notebook" \
  --notebook-mac-document-launch-fixture \
  >"$MAC_SMOKE_LOG" 2>&1 &
MAC_SMOKE_PID=$!
for _ in {1..160}; do
  [[ -f "$MAC_SMOKE_PROOF" ]] && break
  kill -0 "$MAC_SMOKE_PID" >/dev/null 2>&1 || break
  sleep 0.25
done
if ! kill -0 "$MAC_SMOKE_PID" >/dev/null 2>&1; then
  cat "$MAC_SMOKE_LOG" >&2
  printf '%s\n' \
    'Фоновый Mac должен пережить запуск с многостраничным документом без рабочего окна.' >&2
  exit 1
fi
python3 - "$MAC_SMOKE_PROOF" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert p.exists(), "Mac не завершил проверку фонового документа"
proof = json.loads(p.read_text())
assert proof.get("status") == "ready", proof
assert proof.get("workingWindows") == 0 and proof.get("surface") == "document", proof
assert proof.get("pngBytes", 0) > 0 and len(proof.get("pngSHA256", "")) == 64, proof
png = p.with_suffix(".png").read_bytes()
assert len(png) == proof["pngBytes"] and hashlib.sha256(png).hexdigest() == proof["pngSHA256"], proof
PY
kill "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
wait "$MAC_SMOKE_PID" >/dev/null 2>&1 || true
MAC_SMOKE_PID=""
xcodebuild \
  -quiet \
  -project Notebook.xcodeproj \
  -scheme NotebookMac \
  -configuration Debug \
  -collect-test-diagnostics never \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED/mac-tests" \
  -resultBundlePath "$EVIDENCE/mac.xcresult" \
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
  -resultBundlePath "$EVIDENCE/ipad.xcresult" \
  test \
  -only-testing:NotebookTests \
  -only-testing:NotebookUITests/DrawingResponsivenessTests

for platform in mac ipad; do
  xcrun xcresulttool get test-results summary \
    --path "$EVIDENCE/$platform.xcresult" --compact \
    >"$EVIDENCE/$platform-summary.json"
  python3 - "$EVIDENCE/$platform-summary.json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
if summary.get("failedTests", 0) or summary.get("skippedTests", 0):
    raise SystemExit("Полный маршрут не допускает ошибок или пропущенных тестов.")
if not summary.get("passedTests", 0):
    raise SystemExit("Полный маршрут должен исполнить тесты, а не только собрать приложение.")
warnings = summary.get("runtimeWarnings", [])
if warnings:
    for warning in warnings:
        print(warning.get("message", str(warning)), file=sys.stderr)
    raise SystemExit("Проверка исполнения не допускает предупреждений runtime.")
PY
done

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
