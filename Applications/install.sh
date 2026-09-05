#!/bin/bash
set -euo pipefail

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
if [[ $# -ne 1 ]]; then
  printf 'Использование: %s <iPad device identifier из xcrun devicectl list devices>\n' "$0" >&2
  exit 2
fi
DEVICE_ID=$1
mkdir -p "$ROOT/.build"
OUTPUT=$(mktemp -d "$ROOT/.build/install.XXXXXX")
APP_STAGE=""
cleanup() {
  if [[ -n "$APP_STAGE" ]]; then rm -rf "$APP_STAGE"; fi
}
trap cleanup EXIT
printf 'Проверка и квитанции установки: %s\n' "$OUTPUT"

# This fingerprint includes tracked and newly added source files, and stays
# fixed from verification through both builds. Generated build folders are ignored.
source_revision() {
  git -C "$ROOT" ls-files -co --exclude-standard -z -- Sources Tests Applications MCP Package.swift verify.sh |
    python3 -c 'import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); digest=hashlib.sha256()
for name in sorted(set(sys.stdin.buffer.read().split(b"\0")) - {b""}):
    path = root / name.decode()
    digest.update(name + b"\0"); digest.update(path.read_bytes() if path.is_file() else b"\0deleted")
print(digest.hexdigest())' "$ROOT"
}
SOURCE_REVISION=$(source_revision)
printf '%s\n' "$SOURCE_REVISION" > "$OUTPUT/source.sha256"
"$ROOT/verify.sh" > "$OUTPUT/verify.log" 2>&1
cd "$ROOT/Applications"
xcodegen generate
xcodebuild -quiet -project Notebook.xcodeproj -scheme NotebookMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUTPUT/mac" CODE_SIGNING_ALLOWED=NO build \
  > "$OUTPUT/mac-build.log" 2>&1
xcodebuild -quiet -project Notebook.xcodeproj -scheme Notebook \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUTPUT/ipad" build > "$OUTPUT/ipad-build.log" 2>&1

if [[ "$(source_revision)" != "$SOURCE_REVISION" ]]; then
  printf 'Исходники изменились во время проверки. Запустите установку нового среза.\n' >&2
  exit 1
fi

# A verified pair is staged before either installed application is changed.
mkdir -p "$HOME/Applications"
APP_STAGE=$(mktemp -d "$HOME/Applications/.notebook-install.XXXXXX")
ditto "$OUTPUT/mac/Build/Products/Release/Notebook.app" "$APP_STAGE/Notebook.app"
xcrun devicectl device install app --device "$DEVICE_ID" \
  "$OUTPUT/ipad/Build/Products/Release-iphoneos/Notebook.app" \
  --json-output "$OUTPUT/ipad-install.json"
if pgrep -f "^$HOME/Applications/Notebook.app/Contents/MacOS/Notebook" >/dev/null; then
  osascript -e 'tell application id "com.amirtlinov.notebook.mac" to quit'
  for _ in {1..50}; do
    if ! pgrep -f "^$HOME/Applications/Notebook.app/Contents/MacOS/Notebook" >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -f "^$HOME/Applications/Notebook.app/Contents/MacOS/Notebook" >/dev/null; then
    printf 'Завершите работу текущего Notebook на Mac и повторите установку.\n' >&2
    exit 1
  fi
fi
if [[ -d "$HOME/Library/Application Support/Notebook" ]]; then
  ditto "$HOME/Library/Application Support/Notebook" "$OUTPUT/workspace-before-install"
fi
if [[ -d "$HOME/Applications/Notebook.app" ]]; then
  mv "$HOME/Applications/Notebook.app" "$OUTPUT/previous-Notebook.app"
fi
mv "$APP_STAGE/Notebook.app" "$HOME/Applications/Notebook.app"
open -gj "$HOME/Applications/Notebook.app"
xcrun devicectl device process launch --device "$DEVICE_ID" \
  com.amirtlinov.notebook --json-output "$OUTPUT/ipad-launch.json"
cd "$ROOT/MCP"
npm run --silent smoke:installed > "$OUTPUT/installed-proof.json"
printf 'Mac и iPad установлены; живое наблюдение подтверждено: %s\n' "$OUTPUT/installed-proof.json"
