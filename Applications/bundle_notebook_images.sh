#!/bin/sh
set -eu
: "${NOTEBOOK_IMAGE_RUNTIME:?Prepare the pinned image compiler before building NotebookMarkupService}"
case "$NOTEBOOK_IMAGE_RUNTIME" in
  /*) ;;
  *) echo 'NOTEBOOK_IMAGE_RUNTIME must be an absolute prepared resource path.' >&2; exit 1 ;;
esac
/usr/bin/env python3 -B "$SRCROOT/prepare_notebook_images.py" --check --stage "$NOTEBOOK_IMAGE_RUNTIME" \
  --output-list "$SRCROOT/NotebookImageResources.xcfilelist"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
compiler="$NOTEBOOK_IMAGE_RUNTIME/Helpers/notebook-image-compiler"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  : "${EXPANDED_CODE_SIGN_IDENTITY:?The image compiler requires the service signing identity}"
  : "${TARGET_TEMP_DIR:?The image compiler must be signed in the target temporary directory}"
  temporary=$(/usr/bin/mktemp -d "$TARGET_TEMP_DIR/notebook-images.XXXXXX")
  trap '/bin/rm -rf "$temporary"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  /usr/bin/ditto --noqtn --norsrc "$compiler" "$temporary/notebook-image-compiler"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
    --identifier com.amirtlinov.notebook.image-compiler \
    --entitlements "$SRCROOT/../Sources/NotebookMarkupService/tex-child.entitlements.plist" \
    "$temporary/notebook-image-compiler"
  compiler="$temporary/notebook-image-compiler"
fi
/bin/mkdir -p "$destination/Helpers"
/usr/bin/ditto --noqtn --norsrc "$compiler" "$destination/Helpers/notebook-image-compiler"
/usr/bin/ditto --noqtn --norsrc "$NOTEBOOK_IMAGE_RUNTIME/Resources/NotebookImages" "$destination/Resources/NotebookImages"
