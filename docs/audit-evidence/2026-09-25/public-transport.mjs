import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const repo=resolve(process.argv[2] ?? process.cwd());
const root=await mkdtemp(join(tmpdir(),'notebook-audit-transport-'));
try {
 const contents=join(root,'Fixture.app','Contents');
 const bundle=join(contents,'Resources','NotebookTools');
 await mkdir(contents,{recursive:true});
 await writeFile(join(contents,'Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.amirtlinov.notebook.mac.acceptance</string></dict></plist>`);
 const build=spawnSync(process.execPath,[join(repo,'MCP/build-sidecar.mjs'),bundle],{encoding:'utf8'});
 if(build.status!==0)throw new Error(build.stderr);
 const id=randomUUID(), endpoint=join(root,'endpoint.json');
 await writeFile(endpoint,JSON.stringify({version:1,runID:id,workspaceID:randomUUID(),sourceSHA256:'a'.repeat(64),socket:`/tmp/notebook-acceptance-${id}/bridge.sock`,macApp:join(root,'Fixture.app')}));
 const result=spawnSync(process.execPath,[join(repo,'MCP/public-transport.mjs'),endpoint,'list-tools'],{encoding:'utf8',timeout:15000});
 console.log(JSON.stringify({test:'actual MCP bundle against checked-in public verification client; no Mac process/socket/store',exitCode:result.status,stdout:result.stdout.trim(),stderr:result.stderr.trim()},null,2));
 if(result.status!==1||!result.stderr.includes('exactly the two public Notebook tools'))throw new Error('Expected inventory mismatch not reproduced');
} finally { await rm(root,{recursive:true,force:true}); }
