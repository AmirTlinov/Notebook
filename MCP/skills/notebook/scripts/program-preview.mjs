#!/usr/bin/env node
import {createServer} from 'node:http';
import {open,readFile,stat,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {SourceMap} from 'node:module';
import {resolve,join,posix} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {previewDocument,loadBrowserBridge} from './animation-preview.mjs';
import {prepareProgramPackage,validProgramPath} from './program-package.mjs';

const stamp=s=>[s.dev,s.ino,s.size,s.mtimeNs,s.ctimeNs].join(':');
const hash=source=>createHash('sha256').update(source).digest('hex');
const bounded=async(request,limit)=>{
  const chunks=[];let size=0;
  for await(const chunk of request){size+=chunk.length;if(size>limit)throw new Error('Diagnostic too large');chunks.push(chunk);}
  return Buffer.concat(chunks).toString('utf8');
};

/** Local author preview of an immutable prepared package, not an application server. */
export async function startProgramPreview(descriptor,{state={},onDiagnostic=()=>{}}={}) {
  const pkg=descriptor.package;
  if(!pkg?.files?.length||!Array.isArray(descriptor.sources))throw new Error('Expected a prepared program descriptor');
  const first=descriptor.sources[0],root=first&&first.sourcePath.slice(0,-first.path.length);
  if(!root)throw new Error('Prepared files have no directory');
  for(const source of descriptor.sources)if(!validProgramPath(source.path)||await realpath(join(root,source.path))!==source.sourcePath)
    throw new Error('Prepared source paths do not match their package directory');
  const checked=await prepareProgramPackage({directory:root,...pkg,files:pkg.files.map(file=>file.path)});
  if(checked.packageHash!==descriptor.packageHash)throw new Error('Prepared bytes no longer match their package identity');
  const files=new Map();
  for(const source of checked.sources)files.set(source.path,{...pkg.files.find(file=>file.path===source.path),source:source.sourcePath,
    stamp:stamp(await stat(source.sourcePath,{bigint:true}))});
  const capability=randomUUID(),prefix='/'+capability+'/',diagnostics=[],maps=new Map();let origin,active=0;
  const identity={packageHash:checked.packageHash,bridge:hash(loadBrowserBridge().source),build:descriptor.build?.key??null};
  async function diagnose(message) {
    const result={stage:String(message.stage??'runtime').slice(0,80),message:String(message.message??'').slice(0,4096)};
    let file=message.file,line=Number(message.line),column=Number(message.column);
    if(!file||!line){const match=String(message.stack??'').match(/(http:\/\/127\.0\.0\.1:\d+\/[^\s)]+):(\d+):(\d+)/);if(match){file=match[1];line=Number(match[2]);column=Number(match[3]);}}
    if(typeof file==='string'&&file.startsWith(origin+prefix)&&Number.isSafeInteger(line)&&line>0) {
      const path=file.slice((origin+prefix).length),entry=files.get(path+'.map');
      result.generated={file:path,line,column};
      if(entry&&entry.byteCount<=16*1024*1024){
        if(!maps.has(path))maps.set(path,new SourceMap(JSON.parse(await readFile(entry.source,'utf8'))));
        const mapped=maps.get(path).findEntry(line-1,Math.max(0,column-1));
        if(mapped.originalSource)result.source={file:posix.normalize(posix.join('.notebook/out',mapped.originalSource)),line:mapped.originalLine+1,column:mapped.originalColumn+1};
      }
    }
    diagnostics.push(result);if(diagnostics.length>20)diagnostics.shift();onDiagnostic(result);return result;
  }
  const server=createServer(async(request,response)=>{
    let handle;
    try {
      if(request.headers.host!==origin.slice(7)||!request.url?.startsWith(prefix)||/[?#%\\]/.test(request.url)) {response.writeHead(404).end();return;}
      const path=request.url.slice(prefix.length);
      if(path==='_diagnostic'&&request.method==='POST') {
        if(request.headers.origin&&request.headers.origin!==origin){response.writeHead(403).end();return;}
        const diagnostic=await diagnose(JSON.parse(await bounded(request,16*1024)));response.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'}).end(JSON.stringify(diagnostic));return;
      }
      if(!['GET','HEAD'].includes(request.method)){response.writeHead(405).end();return;}
      if(path&&!validProgramPath(path)){response.writeHead(404).end();return;}
      const entry=files.get(path||pkg.html),isRoot=path==='';
      if(!isRoot&&!entry){response.writeHead(404).end();return;}
      if(active>=64){response.writeHead(503).end();return;}active++;
      try {
        const policy=`default-src 'none';img-src data: blob: ${origin};style-src 'unsafe-inline' ${origin};script-src 'unsafe-inline' 'wasm-unsafe-eval' ${origin};connect-src ${origin};font-src data: ${origin};media-src data: blob: ${origin};worker-src blob: ${origin};frame-src 'none';form-action 'none';base-uri 'none';object-src 'none'`;
        const parts=isRoot?previewDocument({state,policy,identity,diagnosticsURL:prefix+'_diagnostic',
          cssURL:pkg.css?prefix+pkg.css:undefined,scriptURL:pkg.javaScript?prefix+pkg.javaScript:undefined,module:pkg.module}):{before:'',after:''};
        if(entry){handle=await open(entry.source,constants.O_RDONLY|constants.O_NONBLOCK|constants.O_NOFOLLOW);
          if(stamp(await handle.stat({bigint:true}))!==entry.stamp){response.writeHead(409).end('Prepared file changed; prepare again');return;}}
        let start=0,end=(entry?.byteCount??0)-1,code=200;
        const headers={'Content-Type':isRoot?'text/html; charset=utf-8':entry.mimeType,'Content-Security-Policy':policy,
          'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Accept-Ranges':'bytes'};
        if(request.headers.range){
          const match=request.headers.range.match(/^bytes=(\d*)-(\d*)$/),size=entry?.byteCount??0;
          if(match&&(match[1]||match[2])&&!isRoot){
            start=match[1]?Number(match[1]):Math.max(0,size-Number(match[2]));
            end=match[1]&&match[2]?Math.min(size-1,Number(match[2])):size-1;
          }
          if(!match||!(match[1]||match[2])||isRoot||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=size){response.writeHead(416,{'Content-Range':`bytes */${size}`}).end();return;}
          code=206;headers['Content-Range']=`bytes ${start}-${end}/${size}`;
        }
        headers['Content-Length']=String(Math.max(0,end-start+1)+Buffer.byteLength(parts.before)+Buffer.byteLength(parts.after));
        response.writeHead(code,headers);if(request.method==='HEAD'){response.end();return;}
        async function* content(){yield parts.before;if(handle&&end>=start)yield* handle.createReadStream({start,end,highWaterMark:1_048_576,autoClose:false});yield parts.after;}
        await pipeline(Readable.from(content(),{objectMode:false}),response);
      }finally{active--;await handle?.close();}
    }catch(error){if(!response.headersSent)response.writeHead(400).end(String(error.message));else response.destroy(error);}
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  origin='http://127.0.0.1:'+server.address().port;
  return {url:origin+prefix,identity,diagnostics,close:()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections();})};
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [input,...extra]=process.argv.slice(2);
  try {
    if(!input||extra.length)throw new Error('Usage: node program-preview.mjs prepared-program.json');
    const preview=await startProgramPreview(JSON.parse(await readFile(input,'utf8')),{onDiagnostic:value=>process.stderr.write(JSON.stringify(value)+'\n')});
    process.stdout.write(JSON.stringify({url:preview.url,...preview.identity,runtime:'local-browser'})+'\n');
    for(const name of ['SIGINT','SIGTERM'])process.once(name,()=>void preview.close());
  }catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
}
