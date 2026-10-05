import {spawnSync} from 'node:child_process';
import {access,readFile,mkdir,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export async function buildSurface(){
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
  const source=await readFile(resolve(root,'Sources/NotebookSurfaceWasm/SurfaceABI.swift'),'utf8');
  const exports=[...source.matchAll(/@_cdecl\("([a-z_]+)"\)/g)].map(match=>match[1]);
  const args=['build','--swift-sdk','swift-6.4.0-RELEASE_wasm','--scratch-path',resolve(root,'.build/surface-wasm'),
    '--product','notebook-surface','-c','release','-Xswiftc','-Xclang-linker','-Xswiftc','-mexec-model=reactor','-Xlinker','--strip-all',
    ...exports.flatMap(name=>['-Xlinker',`--export=${name}`])];
  run(args);
  const path=resolve(run([...args,'--show-bin-path']),'notebook-surface.wasm');
  const bytes=await readFile(path),module=new WebAssembly.Module(bytes);
  for(const name of exports)if(!WebAssembly.Module.exports(module).some(value=>value.name===name))throw new Error(`Missing surface export: ${name}`);
  const receipt={compiler,sdk:'swift-6.4.0-RELEASE_wasm',path,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),exports};
  const output=resolve(root,'.build/surface');await mkdir(output,{recursive:true});
  await writeFile(resolve(output,'build.json'),JSON.stringify(receipt,null,2)+'\n');
  return {bytes,receipt};
}
if(process.argv[1]===fileURLToPath(import.meta.url))console.log(JSON.stringify((await buildSurface()).receipt,null,2));
