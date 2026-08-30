#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$ROOT/AppIcon.svg"
OUTPUT_DIR=${1:-"$ROOT/Assets.xcassets/AppIcon.appiconset"}
mkdir -p "$OUTPUT_DIR"

render() {
  name=$1
  pixels=$2
  rsvg-convert --width "$pixels" --height "$pixels" "$SOURCE" \
    > "$OUTPUT_DIR/$name"
}

# One edge-filling SVG owns both platforms. Apple supplies the final device
# mask; the asset catalog receives no second inset or platform-specific copy.
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
