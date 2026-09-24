#!/usr/bin/env bash
# Exact current normalizer vs one-loop single-pass control. All artifacts stay in /tmp.
# Usage: bash quickjs-ab.sh /absolute/path/to/Notebook
set -euo pipefail
repo="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo"
out="$(mktemp -d "${TMPDIR:-/tmp}/notebook-markup-audit.XXXXXX")"
export NOTEBOOK_AUDIT_OUT="$out"
python3 - <<'PY'
import hashlib,json,os
from pathlib import Path
out=Path(os.environ['NOTEBOOK_AUDIT_OUT'])
source=Path('Sources/NotebookMarkupService/Resources/notebook-markup.js')
text=source.read_text()
needle='for (const [placeholder, formula] of math) text = text.split(placeholder).join(formula);'
assert text.count(needle)==1, 'Source changed: re-review control before running'
replacement=r'const mathValues = new Map(math); text = text.replace(/NOTEBOOKTEXMATHX*\d+TOKEN/g, token => mathValues.get(token) ?? token);'
(out/'single-pass.js').write_text(text.replace(needle,replacement))
for count in [4000,8000,16000]:
    body=' '.join('Equation %s: $x_{%s}^2+y^2=1$.'%(i,i) for i in range(count))
    value={'kind':'documentTeX','document':{'id':'11111111-1111-1111-1111-111111111111','paperSize':'a4','preamble':'','blocks':[{'id':'math','kind':'markdown','source':body}]}}
    (out/('input-%s.json'%count)).write_text(json.dumps(value))
    print(json.dumps({'formulas':count,'sourceBytes':len(body.encode())}))
print('bundleSHA256='+hashlib.sha256(source.read_bytes()).hexdigest())
PY
cat >"$out/probe.c" <<'C'
#include "NotebookQuickJS.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static char *readfile(const char *path) {
  FILE *f=fopen(path,"rb"); if(!f) return NULL;
  fseek(f,0,SEEK_END); long n=ftell(f); rewind(f);
  char *b=malloc(n+1); if(!b || fread(b,1,n,f)!=(size_t)n) abort();
  b[n]=0; fclose(f); return b;
}
int main(int argc,char **argv) {
  if(argc!=3) return 2;
  char *src=readfile(argv[1]), *args=readfile(argv[2]); if(!src||!args) return 3;
  double start=(double)clock()/CLOCKS_PER_SEC;
  NQRuntime *r=nq_create(64*1024*1024,1024*1024,2,NULL,NULL); if(!r) return 4;
  nq_set_result_limit(r,24*1024*1024);
  int status=nq_bootstrap(r,src);
  if(!status) status=nq_start(r,"return notebookMarkup(args);",args);
  if(!status) do { status=nq_pump(r); } while(status==0);
  char *result=status==1 ? nq_result(r) : nq_error(r);
  printf("status=%d cpuSeconds=%.6f outputBytes=%zu result=%s\n",status,
    (double)clock()/CLOCKS_PER_SEC-start,result?strlen(result):0,status==1?"ok":result);
  nq_free_string(result); nq_destroy(r); free(src); free(args); return 0;
}
C
clang -O2 -D_GNU_SOURCE '-DCONFIG_VERSION="2026-06-04"' -ISources/CQuickJS/include \
  "$out/probe.c" Sources/CQuickJS/{quickjs,dtoa,libregexp,libunicode,cutils,notebook-quickjs}.c \
  -o "$out/probe"
for n in 4000 8000 16000; do
  echo "formulas=$n current"
  "$out/probe" Sources/NotebookMarkupService/Resources/notebook-markup.js "$out/input-$n.json"
  echo "formulas=$n single-pass-control"
  "$out/probe" "$out/single-pass.js" "$out/input-$n.json"
done | tee "$out/native-ab.txt"
# The control must preserve the whole result, not just its length. V8 runs without CPU cap.
node <<'JS' | tee "$out/exact-output.txt"
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const out=process.env.NOTEBOOK_AUDIT_OUT;
function load(file){const scope={};vm.createContext(scope);vm.runInContext(fs.readFileSync(file,'utf8'),scope);return scope;}
const a=load('Sources/NotebookMarkupService/Resources/notebook-markup.js'),b=load(out+'/single-pass.js');
for(const formulas of [4000,8000,16000]) {
  const args=JSON.parse(fs.readFileSync(`${out}/input-${formulas}.json`));
  const left=JSON.parse(JSON.stringify(a.notebookMarkup(args))),right=JSON.parse(JSON.stringify(b.notebookMarkup(args)));
  assert.deepStrictEqual(left,right);
  console.log(JSON.stringify({formulas,sameExactOutput:true,outputBytes:Buffer.byteLength(JSON.stringify(left))}));
}
JS
printf 'Artifacts (temporary only): %s\n' "$out"
