import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, mkdir, writeFile, rm, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash, randomUUID} from 'node:crypto';
import {spawnSync} from 'node:child_process';

test('public verifier accepts current three-tool bundle only in its checkout scope', {skip:process.platform !== 'darwin'}, async () => {
  const repo=await realpath(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
  const root=await mkdtemp(join(tmpdir(),'notebook-public-transport-'));
  try {
    const app=join(root,'Fixture.app'), contents=join(app,'Contents');
    const bundle=join(contents,'Resources','NotebookTools');
    await mkdir(contents,{recursive:true});
    const build=spawnSync(process.execPath,[join(repo,'MCP/build-sidecar.mjs'),bundle],{encoding:'utf8'});
    assert.equal(build.status,0,build.stderr);
    const id=randomUUID(), endpoint=join(root,'endpoint.json');
    const configuration={version:1,runID:id,workspaceID:randomUUID(),sourceSHA256:'a'.repeat(64),socket:`/tmp/notebook-acceptance-${id}/bridge.sock`,macApp:app};
    await writeFile(endpoint,JSON.stringify(configuration));
    const info=async (identifier:string)=>writeFile(join(contents,'Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${identifier}</string></dict></plist>`);
    const invoke=(...args:string[])=>spawnSync(process.execPath,[join(repo,'MCP/public-transport.mjs'),endpoint,...args],{encoding:'utf8',timeout:15000,input:'{}'});
    const scope=createHash('sha256').update(repo).digest('hex').slice(0,12);
    await info(`com.amirtlinov.notebook.mac.acceptance.${scope}`);
    const listed=invoke('list-tools');
    assert.equal(listed.status,0,listed.stderr);
    assert.deepEqual(JSON.parse(listed.stdout).tools.map((x:{name:string})=>x.name).sort(),['notebook_context','notebook_execute','notebook_import_program']);
    assert.equal(invoke('call','notebook_import_program').status,1,'Extra server tool is not extra client authority');
    for(const identifier of ['com.amirtlinov.notebook.mac','com.amirtlinov.notebook.mac.acceptance','com.amirtlinov.notebook.mac.acceptance.000000000000']) {
      await info(identifier); const denied=invoke('list-tools');
      assert.equal(denied.status,1); assert.match(denied.stderr,/this checkout/);
    }
    await info(`com.amirtlinov.notebook.mac.acceptance.${scope}`);
    await writeFile(endpoint,JSON.stringify({...configuration,socket:'/tmp/notebook-production/bridge.sock'}));
    assert.match(invoke('list-tools').stderr,/private acceptance socket/);
    await writeFile(endpoint,JSON.stringify(configuration));
    // This negative fixture exercises the protocol boundary, not a replacement server.
    await writeFile(join(bundle,'dist/index.mjs'),`import {createInterface} from 'node:readline';
      for await(const line of createInterface({input:process.stdin})) { const m=JSON.parse(line); if(m.id) console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:m.method==='tools/list'?{tools:[]}:{}})); }`);
    assert.match(invoke('list-tools').stderr,/public Notebook tools/);
  } finally {await rm(root,{recursive:true,force:true});}
});
