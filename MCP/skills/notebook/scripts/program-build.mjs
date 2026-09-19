import {readFile,writeFile,mkdir,mkdtemp,rm,rename,copyFile,stat,readdir,realpath} from 'node:fs/promises';
import {createReadStream,constants} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {createRequire} from 'node:module';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve,dirname,relative,extname,sep,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import * as esbuild from 'esbuild';
import {prepareProgramPackage,canonicalProgramJSON,validProgramPath} from './program-package.mjs';
import {loadBrowserBridge} from './animation-preview.mjs';

const run=promisify(execFile),require=createRequire(import.meta.url);
const tscPackage=require.resolve('typescript/package.json'),tsc=join(dirname(tscPackage),'bin/tsc');
const browserTypes=fileURLToPath(new URL('../references/notebook-browser.d.ts',import.meta.url));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const canonical=canonicalProgramJSON;
const fileTypes=['svg','png','jpg','jpeg','webp','gif','avif','woff','woff2','ttf','otf','mp4','webm','mp3','m4a','wav','ogg','wasm','gltf','glb','csv','bin'];
const filePattern=new RegExp('\\.('+fileTypes.join('|')+')$','i');
export class ProgramBuildError extends Error {
  constructor(stage,diagnostics) {
    super(diagnostics.map(d=>[d.file&&`${d.file}${d.line?`:${d.line}:${d.column??1}`:''}`,d.message].filter(Boolean).join(': ')).join('\n'));
    this.stage=stage;this.diagnostics=diagnostics;
  }
}
const problem=(stage,message)=>new ProgramBuildError(stage,[{message}]);
const inside=(root,path)=>path.startsWith(root+sep);
async function regular(path) {
  const info=await stat(path,{bigint:true});
  if(!info.isFile()||info.size>BigInt(Number.MAX_SAFE_INTEGER))throw problem('files','Expected a regular source file: '+path);
  return {bytes:Number(info.size),stamp:[info.dev,info.ino,info.size,info.mtimeNs,info.ctimeNs].join(':')};
}
async function digest(path,previous) {
  const before=await regular(path);
  if(previous?.stamp===before.stamp)return {...before,sha256:previous.sha256};
  const value=createHash('sha256');
  for await(const bytes of createReadStream(path,{highWaterMark:1_048_576,flags:constants.O_RDONLY|constants.O_NONBLOCK|constants.O_NOFOLLOW}))value.update(bytes);
  if((await regular(path)).stamp!==before.stamp)throw problem('files','Source changed during build: '+path);
  return {...before,sha256:value.digest('hex')};
}
async function capture(paths,previous={}) {
  const records={};
  for(const path of [...new Set(paths)].sort())records[path]=await digest(path,previous[path]);
  return records;
}
async function directoryIdentity(paths,root) {
  const dirs=new Set();
  for(const path of paths) {
    for(let dir=dirname(path);inside(root,dir)||dir===root;dir=dirname(dir)) {
      dirs.add(dir);if(dir===root)break;
    }
  }
  const result=[];
  for(const dir of [...dirs].sort())result.push([relative(root,dir),(await readdir(dir)).filter(name=>name!=='.git'&&name!=='.notebook').sort()]);
  return result;
}
async function optionalJSON(path) {
  try{return JSON.parse(await readFile(path,'utf8'));}catch(error){if(error.code==='ENOENT')return null;throw error;}
}
function diagnostic(error,root) {
  return (error.errors??[{text:error.message}]).map(d=>({message:d.text,
    ...(d.location?{file:relative(root,resolve(root,d.location.file)),line:d.location.line,column:d.location.column+1}: {})}));
}

/** Author-side compiler, never a QuickJS capability or an application package manager. */
export async function buildProgram(input,{signal}={}) {
  const root=await realpath(input.directory??'.');
  const local=async path=>{
    if(typeof path!=='string'||!path||path.includes('\0'))throw problem('files','Expected a relative source path');
    const file=await realpath(resolve(root,path));
    if(!inside(root,file))throw problem('files','Build input escapes its project: '+path);
    await regular(file);return file;
  };
  const version=JSON.parse(await readFile(tscPackage,'utf8')).version;
  if(version!=='7.0.2'||esbuild.version!=='0.28.2')throw problem('toolchain','Expected pinned TypeScript 7.0.2 and esbuild 0.28.2');
  const entry=await local(input.entry),workers={};
  for(const [name,path] of Object.entries(input.workers??{})) {
    if(!/^[a-zA-Z0-9_-]+$/.test(name)||name.length>80)throw problem('files','Worker names use ASCII letters, digits, - and _');
    workers['worker-'+name]=await local(path);
  }
  const html=input.html?await local(input.html):null,assets=[];
  for(const path of input.assets??[]) {
    if(!validProgramPath(path))throw problem('files','Asset needs a portable package path: '+path);
    assets.push({path,source:await local(path)});
  }
  const configPath=input.tsconfig?await local(input.tsconfig):null;
  const bridge=loadBrowserBridge(),bridgeHash=hash(bridge.source),typesHash=hash(await readFile(browserTypes));
  const options={format:1,entry:relative(root,entry),workers:Object.fromEntries(Object.entries(workers).map(([name,path])=>[name,relative(root,path)])),
    html:html?relative(root,html):null,assets:assets.map(a=>a.path).sort(),tsconfig:configPath?relative(root,configPath):null,
    builder:hash(await readFile(fileURLToPath(import.meta.url))),target:'es2022',typescript:version,esbuild:esbuild.version,bridge:bridgeHash,types:typesHash};
  const cache=join(root,'.notebook','program-builds');await mkdir(cache,{recursive:true,mode:0o700});
  const indexPath=join(cache,hash(canonical(options))+'.json');
  let previous;
  try{previous=await optionalJSON(indexPath);}catch(error){if(!(error instanceof SyntaxError))throw error;}
  const work=await mkdtemp(join(cache,'work-'));
  try {
    signal?.throwIfAborted();
    const assetDeclarations=fileTypes.map(ext=>`declare module "*.${ext}" { const url: string; export default url; }`).join('\n')+'\ndeclare module "*.css";\n';
    const assetTypes=join(work,'assets.d.ts');await writeFile(assetTypes,assetDeclarations);
    const compilerOptions={target:'ES2022',module:'ESNext',moduleResolution:'Bundler',moduleDetection:'force',
      types:[],strict:true,allowJs:true,noEmit:true,incremental:false,composite:false,
      allowImportingTsExtensions:true,resolveJsonModule:true};
    async function typecheck(name,files,lib) {
      const config={...(configPath?{extends:configPath}:{}),compilerOptions:{...compilerOptions,lib},files:[...files,assetTypes],include:[]};
      const path=join(work,name+'.json');await writeFile(path,JSON.stringify(config));
      let checked;
      try{checked=await run(process.execPath,[tsc,'--project',path,'--pretty','false','--listFiles'],{cwd:root,signal,timeout:60000,maxBuffer:16*1_048_576});}
      catch(error){
        const messages=String(error.stdout||error.stderr||error.message).split('\n').filter(line=>line.includes('error TS')).map(line=>{
          const match=line.match(/^(.*?)\((\d+),(\d+)\): error (TS\d+): (.*)$/);
          return match?{file:relative(root,resolve(root,match[1])),line:Number(match[2]),column:Number(match[3]),message:match[4]+': '+match[5]}:{message:line};
        });
        throw new ProgramBuildError('typecheck',messages.length?messages:[{message:String(error.message)}]);
      }
      return {path,files:checked.stdout.split(/\r?\n/).filter(path=>path.startsWith(root+sep)&&!inside(work,path))};
    }
    const mainCheck=await typecheck('main',[entry,browserTypes],['ES2022','DOM','DOM.Iterable']);
    const workerCheck=Object.keys(workers).length?await typecheck('workers',Object.values(workers),['ES2022','WebWorker']):{files:[]};
    // Resolved options include inherited configs without a second JSONC parser.
    const shown=await run(process.execPath,[tsc,'--project',mainCheck.path,'--showConfig'],{cwd:root,signal,maxBuffer:16*1_048_576});
    options.compiler=JSON.parse(shown.stdout).compilerOptions;
    // Paths in the effective configuration are relative to its temporary folder;
    // normalize them for both cache identity and portable provenance.
    for(const name of ['baseUrl','rootDir','outDir','declarationDir','tsBuildInfoFile'])if(options.compiler[name])
      options.compiler[name]=relative(root,resolve(work,options.compiler[name]));
    const typeFiles=[...mainCheck.files,...workerCheck.files];
    const lockPath=join(root,'package-lock.json'),packagePath=join(root,'package.json');
    const lock=await optionalJSON(lockPath),project=await optionalJSON(packagePath);
    const base=[...typeFiles,entry,...Object.values(workers),...assets.map(a=>a.source),...(html?[html]:[]),...(configPath?[configPath]:[]),
      ...(lock?[lockPath]:[]),...(project?[packagePath]:[])];
    const paths=[...base,...Object.keys(previous?.inputs??{}).filter(path=>inside(root,path)&&!inside(cache,path))];
    let before;
    try{before=await capture(paths,previous?.inputs);}catch(error){if(error.code!=='ENOENT')throw error;before=await capture(base);}
    const identify=records=>hash(canonical({options,inputs:Object.entries(records).map(([path,item])=>[relative(root,path),item.sha256,item.bytes])}));
    const initialKey=identify(before),directories=await directoryIdentity(Object.keys(before),root);
    if(previous?.key===initialKey&&canonical(previous.directories)===canonical(directories)&&previous.directory&&inside(cache,previous.directory)) {
      const intact=await Promise.all(Object.entries(previous.outputs??{}).map(async([path,stamp])=>{
        try{return inside(previous.directory,path)&&(await regular(path)).stamp===stamp;}catch{return false;}
      }));
      if(intact.length&&intact.every(Boolean))return {...previous.request,build:{...previous.build,cacheHit:true}};
    }
    const fileAssets=new Map(),sourceReads=new Map(),virtual=join(root,'.notebook','out');
    let bundled;
    try {
      bundled=await esbuild.build({absWorkingDir:root,entryPoints:{main:entry,...workers},outdir:virtual,
        bundle:true,format:'esm',splitting:true,platform:'browser',target:'es2022',sourcemap:'linked',sourcesContent:true,
        entryNames:'[name]',chunkNames:'chunk-[hash]',metafile:true,write:false,legalComments:'eof',logLevel:'silent',
        tsconfig:mainCheck.path,plugins:[{name:'bounded-file-assets',setup(build){
          build.onLoad({filter:/\.(?:[cm]?[jt]sx?|css|json)$/,namespace:'file'},async args=>{
            const source=await local(relative(root,args.path)),record=await regular(source),contents=await readFile(source);
            if((await regular(source)).stamp!==record.stamp)throw problem('files','Source changed during build: '+source);
            sourceReads.set(source,{...record,sha256:hash(contents)});
            const extension=extname(source).slice(1),loader=/^[cm]?[jt]s$/.test(extension)?(extension.includes('t')?'ts':'js'):extension;
            return {contents,loader,resolveDir:dirname(source)};
          });
          build.onResolve({filter:filePattern},async args=>{
            if(args.pluginData?.resolvedAsset)return;
            const result=await build.resolve(args.path,{kind:args.kind,resolveDir:args.resolveDir,importer:args.importer,pluginData:{resolvedAsset:true}});
            if(result.errors.length)return {errors:result.errors};
            if(result.external||!result.path)throw problem('files','An asset must resolve to a local file: '+args.path);
            const source=await local(relative(root,result.path)),record=await digest(source,before[source]);
            const path='asset-'+record.sha256+extname(source).toLowerCase();fileAssets.set(source,{path,source,record});
            return args.kind==='url-token'?{path:'./'+path,external:true}:{path:relative(root,source),namespace:'notebook-file-url'};
          });
          build.onLoad({filter:/.*/,namespace:'notebook-file-url'},args=>({contents:'export default new URL('+JSON.stringify('./'+fileAssets.get(resolve(root,args.path)).path)+',import.meta.url).href',loader:'js'}));
        }}]});
    }catch(error){throw new ProgramBuildError('bundle',diagnostic(error,root));}
    const emittedAssets=new Set([...fileAssets.values()].map(asset=>'./'+asset.path));
    for(const output of Object.values(bundled.metafile.outputs))for(const dependency of output.imports) {
      if(dependency.external&&!emittedAssets.has(dependency.path)&&!dependency.path.startsWith('data:')&&!dependency.path.startsWith('#'))
        throw problem('bundle','External import cannot be published offline: '+dependency.path);
    }
    const imported=[];
    for(const path of Object.keys(bundled.metafile.inputs))if(!path.startsWith('notebook-file-url:'))imported.push(await local(path));
    const packageFiles=[];
    // Package versions are locked; actual used source bytes are additionally
    // recorded below. No npm install, package scripts or network runs here.
    for(const path of imported)if(path.includes(sep+'node_modules'+sep)) {
      const name=relative(root,path).match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1];
      const pin=name&&lock?.packages?.[name],actual=name&&await optionalJSON(join(root,name,'package.json'));
      if(name)packageFiles.push(join(root,name,'package.json'));
      if(!pin?.version||pin.version!==actual?.version||!pin.integrity)throw problem('dependencies','A used browser dependency needs a matching package-lock.json integrity/version: '+name);
    }
    const inputs=await capture([...base,...imported,...fileAssets.keys(),...packageFiles],before);
    for(const [path,item] of [...Object.entries(before),...sourceReads,...[...fileAssets].map(([path,item])=>[path,item.record])])
      if(inputs[path]&&inputs[path].stamp!==item.stamp)throw problem('files','Source changed during build: '+relative(root,path));
    const key=identify(inputs),directory=join(cache,key+'-'+randomUUID()),stage=join(work,'package');await mkdir(stage);
    const names=[];
    for(const output of bundled.outputFiles) {
      const name=relative(virtual,output.path);
      if(!validProgramPath(name))throw problem('bundle','Non-portable output path: '+name);
      await writeFile(join(stage,name),output.contents);names.push(name);
    }
    const copies=new Map();
    for(const asset of [...assets,...fileAssets.values(),...(html?[{path:'view.html',source:html}]:[])]) {
      if(copies.has(asset.path)&&inputs[copies.get(asset.path)].sha256===inputs[asset.source].sha256)continue;
      copies.set(asset.path,asset.source);
      if(names.includes(asset.path))throw problem('files','Asset collides with a compiled output: '+asset.path);
      await mkdir(dirname(join(stage,asset.path)),{recursive:true});await copyFile(asset.source,join(stage,asset.path));names.push(asset.path);
    }
    const provenance={...options,key,inputs:Object.entries(inputs).map(([path,item])=>({path:relative(root,path),sha256:item.sha256,bytes:item.bytes}))};
    await writeFile(join(stage,'notebook-build.json'),canonical(provenance));names.push('notebook-build.json');
    const main=Object.entries(bundled.metafile.outputs).find(([,value])=>value.entryPoint===relative(root,entry));
    const css=main?.[1].cssBundle?relative(virtual,resolve(root,main[1].cssBundle)):undefined;
    const staged=await prepareProgramPackage({directory:stage,files:names,javaScript:'main.js',...(html?{html:'view.html'}:{}),...(css?{css}:{}),module:true},{signal});
    for(const [path,item] of Object.entries(inputs))if((await regular(path)).stamp!==item.stamp)
      throw problem('files','Source changed during build: '+relative(root,path));
    // Publish a fresh immutable directory. Concurrent preparations and existing
    // importers never see an entry deleted or replaced underneath them.
    await rename(stage,directory);
    const request={...staged,sources:staged.sources.map(source=>({...source,sourcePath:join(directory,source.path)}))};
    const build={key,typescript:version,esbuild:esbuild.version,bridge:bridgeHash,directory,cacheHit:false};
    const outputs=Object.fromEntries(await Promise.all(request.sources.map(async s=>[s.sourcePath,(await regular(s.sourcePath)).stamp])));
    const index={key,directory,inputs,directories:await directoryIdentity(Object.keys(inputs),root),outputs,request,build};
    const temporary=join(work,'index.json');await writeFile(temporary,JSON.stringify(index));await rename(temporary,indexPath);
    return {...request,build};
  } finally { await rm(work,{recursive:true,force:true}); }
}
