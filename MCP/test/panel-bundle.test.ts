import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {sealPanelBundle,readPanelBundle,verifyPanelBundle} from '../panel-bundle.mjs';

test('panel identity changes for a native-only release and for browser payload changes',async t=>{
  const html='<html><head></head><body><script>document.getElementById("notebook-panel-identity")</script></body></html>';
  const original=sealPanelBundle(html,'0.2.11'),nativeOnly=sealPanelBundle(html,'0.2.12');
  const changed=sealPanelBundle(html.replace('</body>','<p>New surface</p></body>'),'0.2.11');
  assert.notEqual(nativeOnly.cohort,original.cohort);assert.notEqual(nativeOnly.resourceURI,original.resourceURI);
  assert.notEqual(changed.cohort,original.cohort);assert.notEqual(changed.resourceURI,original.resourceURI);
  const root=await mkdtemp('/tmp/nb-panel-bundle-');t.after(()=>rm(root,{recursive:true,force:true}));
  const path=join(root,'panel-bundle.json');await writeFile(path,JSON.stringify(nativeOnly));
  assert.deepEqual(readPanelBundle(path),nativeOnly);
  assert.throws(()=>verifyPanelBundle({...nativeOnly,html:nativeOnly.html.replace('document.getElementById','document.querySelector')}),/bytes do not match/);
  assert.throws(()=>verifyPanelBundle({...nativeOnly,resourceURI:original.resourceURI}),/Invalid panel bundle identity/);
  assert.throws(()=>verifyPanelBundle({...nativeOnly,html:nativeOnly.html.replace('</body>','<script id="notebook-panel-identity" type="application/json">{}</script></body>')}),/missing or repeated/);
});
