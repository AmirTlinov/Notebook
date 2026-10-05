import {spawnSync} from 'node:child_process';
import {access,readFile,readdir,mkdir,writeFile,rename} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const defaultStage=resolve(root,'.build/surface');
const sdk='swift-6.4.0-RELEASE_wasm';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
async function inputDigest(){
  const files=['Package.swift','MCP/build-surface.mjs'];
  try{await access(resolve(root,'Package.resolved'));files.push('Package.resolved');}catch{}
  async function visit(path){
    for(const entry of await readdir(resolve(root,path),{withFileTypes:true})){
      const child=`${path}/${entry.name}`;
      if(entry.isDirectory())await visit(child);
      else if(entry.isFile())files.push(child);
      else throw new Error(`Surface input must be a regular file: ${child}`);
    }
  }
  await visit('Sources/NotebookSurface');await visit('Sources/NotebookSurfaceWasm');
  return hash(JSON.stringify(await Promise.all(files.sort().map(async path=>[path,hash(await readFile(resolve(root,path)))]))));
}
async function surfaceExports(){
  const source=await readFile(resolve(root,'Sources/NotebookSurfaceWasm/SurfaceABI.swift'),'utf8');
  return [...source.matchAll(/@_cdecl\("([a-z_]+)"\)/g)].map(match=>match[1]);
}
function validateExports(bytes,exports){
  const actual=WebAssembly.Module.exports(new WebAssembly.Module(bytes));
  for(const name of exports)if(!actual.some(value=>value.name===name))throw new Error(`Missing surface export: ${name}`);
}
export async function readSurface(stage){
  const receipt=JSON.parse(await readFile(resolve(stage,'build.json'),'utf8'));
  if(receipt.format!==1||receipt.sdk!==sdk||receipt.sourceSHA256!==await inputDigest())
    throw new Error('Prepared NotebookSurface does not match these sources. Run node MCP/build-surface.mjs before Xcode.');
  const bytes=await readFile(resolve(stage,'notebook-surface.wasm'));
  if(bytes.length!==receipt.bytes||hash(bytes)!==receipt.sha256)throw new Error('Prepared NotebookSurface bytes differ from their build receipt.');
  validateExports(bytes,await surfaceExports());
  return {bytes,receipt};
}
export async function buildSurface(stage=defaultStage){
  const sourceSHA256=await inputDigest();
  const local=resolve(root,'.build/toolchains/swift-6.4.0/swift-6.4.0-RELEASE-osx-package.pkg/Payload/usr/bin/swift');
  let swift=process.env.NOTEBOOK_SWIFT;
  if(!swift){try{await access(local);swift=local;}catch{swift='swift';}}
  const run=(args)=>{
    const result=spawnSync(swift,args,{cwd:root,encoding:'utf8',maxBuffer:8*1024*1024});
    if(result.status!==0)throw new Error([result.error?.message,result.stdout,result.stderr].filter(Boolean).join('\n')||`Swift exited with status ${result.status}`);
    return result.stdout.trim();
  };
  const compiler=run(['--version']);
  if(!compiler.includes('(swift-6.4-RELEASE)'))throw new Error('NotebookSurface requires the official Swift 6.4.0 release toolchain. Set NOTEBOOK_SWIFT to its swift executable and install swift-6.4.0-RELEASE_wasm (see docs/surface-consolidation.md).');
  const exports=await surfaceExports();
  const args=['build','--swift-sdk',sdk,'--scratch-path',resolve(root,'.build/surface-wasm'),
    '--product','notebook-surface','-c','release','-Xswiftc','-Xclang-linker','-Xswiftc','-mexec-model=reactor','-Xlinker','--strip-all',
    ...exports.flatMap(name=>['-Xlinker',`--export=${name}`])];
  run(args);
  const path=resolve(run([...args,'--show-bin-path']),'notebook-surface.wasm');
  const bytes=await readFile(path);validateExports(bytes,exports);
  if(sourceSHA256!==await inputDigest())throw new Error('NotebookSurface sources changed during compilation.');
  const receipt={format:1,compiler,sdk,path:resolve(stage,'notebook-surface.wasm'),sourceSHA256,bytes:bytes.length,sha256:hash(bytes),exports};
  await mkdir(stage,{recursive:true});
  for(const [name,data] of [['notebook-surface.wasm',bytes],['build.json',JSON.stringify(receipt,null,2)+'\n']]){
    const temporary=resolve(stage,`${name}.${process.pid}.tmp`);
    await writeFile(temporary,data);await rename(temporary,resolve(stage,name));
  }
  return {bytes,receipt};
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const args=process.argv.slice(2);let stage=defaultStage,check=false;
  for(let index=0;index<args.length;index++){
    if(args[index]==='--check')check=true;
    else if(args[index]==='--stage'&&args[index+1])stage=resolve(args[++index]);
    else throw new Error('Usage: node MCP/build-surface.mjs [--check] [--stage PATH]');
  }
  console.log(JSON.stringify((await (check?readSurface(stage):buildSurface(stage))).receipt,null,2));
}
