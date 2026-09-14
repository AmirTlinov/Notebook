#!/bin/sh
set -eu

# Build input only: the service resolves its compiler and distribution from its
# signed bundle and never receives this path or the developer's environment.
: "${NOTEBOOK_TEX_RUNTIME:?Prepare pinned TeX resources before building NotebookMarkupService}"
case "$NOTEBOOK_TEX_RUNTIME" in
  /*) ;;
  *) echo 'NOTEBOOK_TEX_RUNTIME must be an absolute prepared resource path.' >&2; exit 1 ;;
esac
/usr/bin/env python3 -B "$SRCROOT/prepare_notebook_tex.py" --check --stage "$NOTEBOOK_TEX_RUNTIME"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
compiler="$NOTEBOOK_TEX_RUNTIME/Helpers/tectonic"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  : "${EXPANDED_CODE_SIGN_IDENTITY:?The embedded compiler requires the service signing identity}"
  : "${TARGET_TEMP_DIR:?The compiler must be signed in the target temporary directory}"
  # Codesign may create temporary files. Keep those in the target's temporary
  # directory; the bundle outputs have an exact, fixed sandbox inventory.
  temporary=$(/usr/bin/mktemp -d "$TARGET_TEMP_DIR/notebook-tex.XXXXXX")
  trap '/bin/rm -rf "$temporary"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  /usr/bin/ditto --noqtn --norsrc "$compiler" "$temporary/tectonic"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
    --identifier com.amirtlinov.notebook.tex-compiler \
    --entitlements "$SRCROOT/../Sources/NotebookMarkupService/tex-child.entitlements.plist" \
    "$temporary/tectonic"
  compiler="$temporary/tectonic"
fi
/bin/mkdir -p "$destination/Helpers"
/usr/bin/ditto --noqtn --norsrc "$compiler" "$destination/Helpers/tectonic"
/usr/bin/ditto --noqtn --norsrc "$NOTEBOOK_TEX_RUNTIME/Resources/NotebookTeX" "$destination/Resources/NotebookTeX"
