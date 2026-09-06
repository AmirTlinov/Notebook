#!/bin/bash
set -euo pipefail
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/notebook-fixture-test.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
SOURCE="$ROOT/LoadFixtures/main.swift"
HASH=$(shasum -a 256 "$SOURCE" | awk '{print $1}')
xcrun swiftc -O "$SOURCE" -o "$BUILD/generate"
for name in first repeated; do
  "$BUILD/generate" "$BUILD/$name" 32 410041 "$HASH" > "$BUILD/$name.log"
  python3 "$ROOT/LoadFixtures/verify.py" "$BUILD/$name"
done
cmp "$BUILD/first/manifest.json" "$BUILD/repeated/manifest.json"
"$BUILD/generate" "$BUILD/different" 8 410042 "$HASH" >/dev/null
python3 "$ROOT/LoadFixtures/verify.py" "$BUILD/different"
if "$BUILD/generate" "$BUILD/first" 32 410041 "$HASH" >"$BUILD/collision.log" 2>&1; then
  echo 'Generator must refuse an existing directory' >&2; exit 1
fi
cmp "$BUILD/first/manifest.json" "$BUILD/repeated/manifest.json"
for count in 0 -1 100001; do
  if "$BUILD/generate" "$BUILD/invalid" "$count" 410041 "$HASH" >/dev/null 2>&1; then
    echo 'Generator accepted an invalid workload size' >&2; exit 1
  fi
  [[ ! -e "$BUILD/invalid" ]]
done
python3 - "$BUILD" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
a=[json.loads(line) for line in (root/'first/items.jsonl').read_text().splitlines()]
b=[json.loads(line) for line in (root/'different/items.jsonl').read_text().splitlines()]
assert {i['source']['format'] for i in a} == {'ink.json','md','svg','html','pdf','jpeg','png','heic','heif'}
assert {i['source']['orientation'] for i in a if i['kind']=='image'} == {1,3,6,8}
assert not ({i['source']['sha256'] for i in a} & {i['source']['sha256'] for i in b})
assert not list(root.glob('.*.preparing-*')), 'Failed generation did not clean its own staging directory'
print('Load fixture: all original hashes, stable seed, formats, orientations and collision refusal verified.')
PY
