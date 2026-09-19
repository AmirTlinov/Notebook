import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,writeFile,readFile,mkdir,rm,open} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
// @ts-expect-error Authored file tooling is executable JavaScript.
import {buildProgram} from '../skills/notebook/scripts/program-build.mjs';

async function project(files:Record<string,string>) {
  const root=await mkdtemp(join(tmpdir(),'notebook-ts-'));
  for(const [path,text] of Object.entries(files)) {await mkdir(join(root,path,'..'),{recursive:true});await writeFile(join(root,path),text);}
  return root;
}
const fixture={
  'main.ts':`import {answer} from './model';import logo from './logo.svg';import './style.css';
const label=document.createElement('output');label.textContent=String(answer);document.body.append(label);
const image=new Image();image.src=logo;document.body.append(image);
const worker=new Worker(new URL('./worker-solver.js',import.meta.url),{type:'module'});
notebook.ready(new Promise<void>(resolve=>worker.onmessage=()=>resolve()));worker.postMessage(answer);`,
  'model.ts':'export const answer:number=42;',
  'solver.ts':'const scope=self as DedicatedWorkerGlobalScope;scope.onmessage=(event:MessageEvent<number>)=>scope.postMessage(event.data+1);',
  'style.css':'body{color:rgb(12,34,56);background-image:url(./logo.svg)}',
  'logo.svg':'<svg xmlns="http://www.w3.org/2000/svg" width="7" height="8"/>',
  'view.html':'<h1>TS scene</h1>'
};
const settings=(directory:string)=>({directory,entry:'main.ts',workers:{solver:'solver.ts'},html:'view.html'});
const output=async(result:any,path:string)=>readFile(result.sources.find((source:any)=>source.path===path).sourcePath,'utf8');

test('TS, CSS, imported assets and independently typed workers form one deterministic offline package',async()=>{
  const root=await project(fixture),other=await project(fixture);
  try {
    const first=await buildProgram(settings(root));
    assert.equal(first.build.cacheHit,false);assert.equal(first.package.javaScript,'main.js');assert.equal(first.package.css,'main.css');
    assert.equal(first.package.html,'view.html');assert.equal(first.package.module,true);
    assert.ok(first.package.files.some((file:any)=>file.path==='worker-solver.js'));
    assert.equal(first.package.files.filter((file:any)=>file.path.endsWith('.svg')).length,1);
    assert.match(await output(first,'main.js'),/sourceMappingURL=main.js.map/);
    const map=JSON.parse(await output(first,'main.js.map'));
    assert.ok(map.sources.some((path:string)=>path.endsWith('main.ts')));assert.ok(map.sourcesContent.includes(fixture['main.ts']));
    assert.equal(JSON.parse(await output(first,'notebook-build.json')).typescript,'7.0.2');
    const second=await buildProgram(settings(root));assert.equal(second.build.cacheHit,true);assert.equal(second.packageHash,first.packageHash);
    const relocated=await buildProgram(settings(other));assert.equal(relocated.packageHash,first.packageHash,'no absolute paths or temporary IDs in published bytes');
    await writeFile(join(root,'model.ts'),'export const answer:number=43;');
    const changed=await buildProgram(settings(root));assert.equal(changed.build.cacheHit,false);assert.notEqual(changed.packageHash,first.packageHash);
    assert.match(await output(first,'main.js'),/answer = 42/,'old immutable package survives replacement');
  } finally{await rm(root,{recursive:true,force:true});await rm(other,{recursive:true,force:true});}
});

test('source diagnostics and failed preparation leave the prior artifact intact',async()=>{
  const root=await project({'main.ts':'const n:number=1;notebook.ready(n);'});
  try {
    const good=await buildProgram({directory:root,entry:'main.ts'}),original=await output(good,'main.js');
    await writeFile(join(root,'main.ts'),'const n:number="wrong";notebook.ready(n);');
    await assert.rejects(buildProgram({directory:root,entry:'main.ts'}),(error:any)=>error.stage==='typecheck'&&error.diagnostics.some((d:any)=>d.file==='main.ts'&&d.line===1&&d.message.includes('TS2322')));
    assert.equal(await output(good,'main.js'),original);
    await writeFile(join(root,'main.ts'),'import {x} from "missing-browser-package";notebook.ready(x);');
    await assert.rejects(buildProgram({directory:root,entry:'main.ts'}),(error:any)=>error.stage==='typecheck'&&error.message.includes('missing-browser-package'));
    await assert.rejects(buildProgram({directory:root,entry:'../outside.ts'}));
    await assert.rejects(buildProgram({directory:root,entry:'main.ts'},{signal:AbortSignal.abort()}));
  }finally{await rm(root,{recursive:true,force:true});}
});

test('arbitrary browser dependencies require their lock and changed package metadata invalidates cache',async()=>{
  const root=await project({
    'main.ts':'import {answer} from "any-browser-library";notebook.ready(answer);',
    'node_modules/any-browser-library/package.json':JSON.stringify({name:'any-browser-library',version:'1.2.3',type:'module',main:'index.js',types:'index.d.ts'}),
    'node_modules/any-browser-library/index.js':'export const answer=42;',
    'node_modules/any-browser-library/index.d.ts':'export declare const answer:number;',
  });
  try {
    await assert.rejects(buildProgram({directory:root,entry:'main.ts'}),(error:any)=>error.stage==='dependencies');
    await writeFile(join(root,'package-lock.json'),JSON.stringify({lockfileVersion:3,packages:{'node_modules/any-browser-library':{version:'1.2.3',integrity:'sha512-fixture'}}}));
    const first=await buildProgram({directory:root,entry:'main.ts'});assert.match(await output(first,'main.js'),/answer = 42/);
    assert.equal((await buildProgram({directory:root,entry:'main.ts'})).build.cacheHit,true);
    await writeFile(join(root,'node_modules/any-browser-library/package.json'),JSON.stringify({name:'any-browser-library',version:'1.2.4',main:'index.js',types:'index.d.ts'}));
    await assert.rejects(buildProgram({directory:root,entry:'main.ts'}),(error:any)=>error.stage==='dependencies');
  }finally{await rm(root,{recursive:true,force:true});}
});

test('bounded file plugin copies a 300 MiB asset without putting binary bytes into JS or esbuild output buffers',async()=>{
  const root=await project({'main.ts':'import url from "./large.bin";document.body.dataset.asset=url;notebook.ready(url);'});
  try {
    const file=await open(join(root,'large.bin'),'w');try{await file.truncate(300*1024*1024);}finally{await file.close();}
    const result=await buildProgram({directory:root,entry:'main.ts'});
    const asset=result.package.files.find((file:any)=>file.path.endsWith('.bin'));
    assert.equal(asset.byteCount,300*1024*1024);assert.equal(asset.parts.length,75);
    assert.ok((await output(result,'main.js')).length<1000);assert.ok(JSON.stringify(result).length<20000);
    assert.equal((await buildProgram({directory:root,entry:'main.ts'})).build.cacheHit,true);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('resolver alternatives, inherited tsconfig and duplicate equal asset imports are tracked',async()=>{
  const root=await project({'main.ts':'import {answer} from "./model";import a from "./a.svg";import b from "./b.svg";notebook.ready([answer,a,b]);',
    'model.js':'export const answer=1;', 'a.svg':fixture['logo.svg'],'b.svg':fixture['logo.svg'],
    'base.json':'{"compilerOptions":{"noUnusedLocals":false}}','tsconfig.json':'{"extends":"./base.json"}'});
  try {
    const config={directory:root,entry:'main.ts',tsconfig:'tsconfig.json'};
    const first=await buildProgram(config);assert.equal(first.package.files.filter((f:any)=>f.path.endsWith('.svg')).length,1);
    await writeFile(join(root,'model.ts'),'export const answer=2;');
    const changed=await buildProgram(config);assert.notEqual(changed.packageHash,first.packageHash);assert.match(await output(changed,'main.js'),/answer = 2/);
    await writeFile(join(root,'base.json'),'{"compilerOptions":{"noUnusedLocals":true}}');
    const inherited=await buildProgram(config);assert.notEqual(inherited.build.key,changed.build.key);
    await writeFile(inherited.sources.find((s:any)=>s.path==='main.js').sourcePath,'corrupted derived cache');
    const repaired=await buildProgram(config);assert.equal(repaired.build.cacheHit,false);assert.equal(repaired.packageHash,inherited.packageHash);
    assert.notEqual(repaired.build.directory,inherited.build.directory);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('concurrent builders publish immutable directories with one package identity',async()=>{
  const root=await project(fixture);
  try {
    const [a,b]=await Promise.all([buildProgram(settings(root)),buildProgram(settings(root))]);
    assert.equal(a.packageHash,b.packageHash);assert.equal(await output(a,'main.js'),await output(b,'main.js'));
    assert.equal((await buildProgram(settings(root))).build.cacheHit,true);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('preview serves only verified package files with CSP, ranges and source-mapped diagnostics',async()=>{
  const {startProgramPreview}=await import(new URL('../skills/notebook/scripts/program-preview.mjs',import.meta.url).href);
  const root=await project({'main.ts':'function crash(){throw new Error("authored failure")};crash();notebook.ready(1);','data.bin':'0123456789'});
  let preview:any;
  try {
    const built=await buildProgram({directory:root,entry:'main.ts',assets:['data.bin']});
    preview=await startProgramPreview(built);
    const response=await fetch(preview.url),html=await response.text();
    assert.match(html,/local-browser/);assert.match(html,new RegExp(built.packageHash));assert.match(html,/createNotebookProgram/);
    assert.match(response.headers.get('Content-Security-Policy')!,/worker-src blob: http:\/\/127\.0\.0\.1/);
    const range=await fetch(preview.url+'data.bin',{headers:{Range:'bytes=2-5'}});assert.equal(range.status,206);assert.equal(await range.text(),'2345');
    assert.equal(range.headers.get('content-range'),'bytes 2-5/10');
    const suffix=await fetch(preview.url+'data.bin',{headers:{Range:'bytes=-2'}});assert.equal(await suffix.text(),'89');
    for(const value of ['bytes=2-3,5-6','bytes=-0','bytes=100-'])assert.equal((await fetch(preview.url+'data.bin',{headers:{Range:value}})).status,416);
    assert.equal((await fetch(preview.url+'main.js',{method:'HEAD'})).headers.get('content-type'),'text/javascript');
    for(const path of ['missing.js','%6dain.js','main.js?query=1','../main.js'])assert.equal((await fetch(preview.url+path)).status,404);
    const script=await output(built,'main.js'),line=script.split('\n').findIndex(line=>line.includes('throw new Error'))+1;
    const report=await fetch(preview.url+'_diagnostic',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({stage:'runtime',message:'authored failure',file:preview.url+'main.js',line,column:3})});
    assert.equal(report.status,200);assert.equal(preview.diagnostics.at(-1).source.file,'main.ts');assert.equal(preview.diagnostics.at(-1).source.line,1);
    await writeFile(built.sources.find((source:any)=>source.path==='main.js').sourcePath,'changed');
    assert.equal((await fetch(preview.url+'main.js')).status,409);
    await assert.rejects(startProgramPreview(built),/identity/);
  }finally{await preview?.close();await rm(root,{recursive:true,force:true});}
});

test('native acceptance runs the exact current compiler output, not a manually authored JS substitute',async()=>{
  const {compiledProgramFixture,fixtureURL}=await import(new URL('./compiled-program-fixture.mjs',import.meta.url).href);
  assert.deepEqual(await compiledProgramFixture(),JSON.parse(await readFile(fixtureURL,'utf8')));
});


test('external CSS imports are build errors, not silently broken offline packages',async()=>{
  const root=await project({'main.ts':'import "./style.css";notebook.ready(1);','style.css':'@import "https://example.com/theme.css";body{color:red}'});
  try{await assert.rejects(buildProgram({directory:root,entry:'main.ts'}),(error:any)=>error.stage==='bundle'&&error.message.includes('External import'));}
  finally{await rm(root,{recursive:true,force:true});}
});


test('saving a prepared descriptor beside sources does not copy the same package on the next CLI run',async()=>{
  const {execFileSync}=await import('node:child_process');
  const {fileURLToPath}=await import('node:url');
  const root=await project({'main.ts':'notebook.ready(1);','build.json':'{"entry":"main.ts"}'});
  try {
    const results=[];
    for(const name of ['first.json','second.json']) {
      execFileSync(process.execPath,[fileURLToPath(new URL('../skills/notebook/scripts/prepare.mjs',import.meta.url)),'program',join(root,'build.json'),join(root,name)]);
      results.push(JSON.parse(await readFile(join(root,name),'utf8')));
    }
    assert.equal(results[0].build.cacheHit,false);assert.equal(results[1].build.cacheHit,true);
    assert.equal(results[0].build.directory,results[1].build.directory);
    assert.deepEqual(results[0].sources,results[1].sources);assert.equal(results[0].packageHash,results[1].packageHash);
  }finally{await rm(root,{recursive:true,force:true});}
});
