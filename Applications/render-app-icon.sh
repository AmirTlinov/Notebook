#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$ROOT/AppIcon.svg"
OUTPUT_DIR=${1:-"$ROOT/Assets.xcassets/AppIcon.appiconset"}
STATUS_DIR="$(dirname -- "$OUTPUT_DIR")/NotebookStatusIcon.imageset"
mkdir -p "$OUTPUT_DIR" "$STATUS_DIR"

render() {
  name=$1
  pixels=$2
  rsvg-convert --background-color '#F7F5F1' --width "$pixels" --height "$pixels" "$SOURCE" \
    > "$OUTPUT_DIR/$name"
}

# The approved transparent SVG owns the mark on both platforms. Application
# icons get an opaque paper background; Apple supplies the final device mask.
render AppIcon-1024.png 1024
render AppIcon-16@1x.png 16
render AppIcon-16@2x.png 32
render AppIcon-32@1x.png 32
render AppIcon-32@2x.png 64
render AppIcon-128@1x.png 128
render AppIcon-128@2x.png 256
render AppIcon-256@1x.png 256
render AppIcon-256@2x.png 512
render AppIcon-512@1x.png 512
render AppIcon-512@2x.png 1024

# The menu bar uses the same silhouette as a native light/dark-aware template.
for scale in 1 2; do
  pixels=$((18 * scale))
  rsvg-convert --width "$pixels" --height "$pixels" "$SOURCE" \
    > "$STATUS_DIR/NotebookStatusIcon@${scale}x.png"
done
