#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$ROOT/AppIcon.svg"
OUTPUT=${1:-"$ROOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"}
TEMP=$(mktemp "${TMPDIR:-/tmp}/notebook-ipad-icon.XXXXXX.svg")
trap 'rm -f "$TEMP"' EXIT

# iPadOS supplies the outer squircle. The full-size vector remains the Mac
# master; only its physical notebook is inset inside the iPad icon field.
sed \
  's/<g id="iconArtwork">/<g id="iconArtwork" transform="translate(92.16 92.16) scale(0.82)">/' \
  "$SOURCE" > "$TEMP"
rsvg-convert --width 1024 --height 1024 "$TEMP" > "$OUTPUT"
