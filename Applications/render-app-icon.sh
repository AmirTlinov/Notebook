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
  # Center the painted mark (including the binding stroke), not its old SVG
  # canvas. Leave room inside the system mask without shrinking the menu icon.
  set -- $(LC_ALL=C awk -v pixels="$pixels" 'BEGIN {
    scale = 0.84
    centerX = (8.775 + 82.6) / 2
    centerY = (8 + 83.6) / 2
    printf "%.6f %.6f %.6f", pixels * scale,
      pixels * (0.5 - scale * centerX / 96),
      pixels * (0.5 - scale * centerY / 96)
  }')
  rsvg-convert --background-color '#F7F5F1' \
    --width "$1" --height "$1" --page-width "$pixels" --page-height "$pixels" \
    --left "$2" --top "$3" "$SOURCE" \
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
