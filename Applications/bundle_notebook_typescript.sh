#!/bin/sh
set -eu
: "${NOTEBOOK_TYPESCRIPT_RUNTIME:?Prepare the pinned TypeScript compiler before building NotebookMarkupService}"
case "$NOTEBOOK_TYPESCRIPT_RUNTIME" in
  /*) ;;
  *) echo 'NOTEBOOK_TYPESCRIPT_RUNTIME must be an absolute prepared resource path.' >&2; exit 1 ;;
esac
/usr/bin/env python3 -B "$SRCROOT/prepare_notebook_typescript.py" --check --stage "$NOTEBOOK_TYPESCRIPT_RUNTIME" \
  --output-list "$SRCROOT/NotebookTypeScriptResources.xcfilelist"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
compiler="$NOTEBOOK_TYPESCRIPT_RUNTIME/Helpers/notebook-typescript"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  : "${EXPANDED_CODE_SIGN_IDENTITY:?The TypeScript compiler requires the service signing identity}"
  : "${TARGET_TEMP_DIR:?The TypeScript compiler must be signed in the target temporary directory}"
  temporary=$(/usr/bin/mktemp -d "$TARGET_TEMP_DIR/notebook-typescript.XXXXXX")
  trap '/bin/rm -rf "$temporary"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  /usr/bin/ditto --noqtn --norsrc "$compiler" "$temporary/notebook-typescript"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
    --identifier com.amirtlinov.notebook.typescript-compiler \
    --entitlements "$SRCROOT/../Sources/NotebookMarkupService/tex-child.entitlements.plist" \
    "$temporary/notebook-typescript"
  compiler="$temporary/notebook-typescript"
fi
/bin/mkdir -p "$destination/Helpers"
/usr/bin/ditto --noqtn --norsrc "$NOTEBOOK_TYPESCRIPT_RUNTIME/Resources/NotebookTypeScript" "$destination/Resources/NotebookTypeScript"
/usr/bin/ditto --noqtn --norsrc "$compiler" "$destination/Helpers/notebook-typescript"
/bin/ln -sfn ../Resources/NotebookTypeScript/lib.d.ts "$destination/Helpers/lib.d.ts"
