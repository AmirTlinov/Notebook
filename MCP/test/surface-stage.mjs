import assert from 'node:assert/strict';
import {cp,mkdir,mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {buildSurface,readSurface} from '../build-surface.mjs';

// A prepared module must cross the immutable-copy/Xcode boundary without a
// compiler, and refuse changed sources or bytes before bundling the panel.
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const stage=resolve(root,'.build/surface');
const {receipt}=await buildSurface();
const temporary=await mkdtemp(resolve(root,'.build/surface-stage-check-'));
try{
  for(const path of ['Package.swift','MCP/build-surface.mjs','Sources/NotebookSurface','Sources/NotebookSurfaceWasm']){
    await mkdir(dirname(resolve(temporary,path)),{recursive:true});
    await cp(resolve(root,path),resolve(temporary,path),{recursive:true});
  }
  try{await cp(resolve(root,'Package.resolved'),resolve(temporary,'Package.resolved'));}catch(error){if(error.code!=='ENOENT')throw error;}
  const snapshot=await import(pathToFileURL(resolve(temporary,'MCP/build-surface.mjs')));
  assert.equal((await snapshot.readSurface(stage)).receipt.sha256,receipt.sha256);
  const extra=resolve(temporary,'Sources/NotebookSurface/Added.swift');
  await writeFile(extra,'// newly added source\n');
  await assert.rejects(snapshot.readSurface(stage),/does not match these sources/);
  await rm(extra);
  await writeFile(resolve(temporary,'Package.swift'),'// changed manifest\n');
  await assert.rejects(snapshot.readSurface(stage),/does not match these sources/);
  const corrupt=resolve(temporary,'corrupt-stage');
  await cp(stage,corrupt,{recursive:true});
  const bytes=await readFile(resolve(corrupt,'notebook-surface.wasm'));bytes[bytes.length-1]^=1;
  await writeFile(resolve(corrupt,'notebook-surface.wasm'),bytes);
  await assert.rejects(readSurface(corrupt),/bytes differ from their build receipt/);
  console.log(JSON.stringify({status:'passed',sha256:receipt.sha256,checks:['immutable copy','source addition','manifest change','corrupt module']}));
}finally{await rm(temporary,{recursive:true,force:true});}
