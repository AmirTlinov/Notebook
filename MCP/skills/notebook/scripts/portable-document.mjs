import {open,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {constants} from 'node:fs';
import {dirname,join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {canonicalProgramJSON,validProgramPath,partBytes} from './program-package.mjs';
const digest=value=>createHash('sha256').update(value).digest('hex');
const hash=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const response=reply=>{if(reply.isError)throw Error(JSON.stringify(reply));return reply.structuredContent??reply;};
const delay=()=>new Promise(resolve=>setTimeout(resolve,250));

/** Same import owner for authored flat files and exported addressed parts. */
export async function stageProgram(client,descriptor,path,signal) {
  signal?.throwIfAborted();
  let result=response(await client.callTool({name:'notebook_import_program',arguments:{op:'start',packageHash:descriptor.packageHash,manifestPath:resolve(path)}})),cancelled=false;
  while(result.status==='staging') {
    if(signal?.aborted&&!cancelled){cancelled=true;await client.callTool({name:'notebook_import_program',arguments:{op:'cancel',packageHash:descriptor.packageHash}});}
    await delay();result=response(await client.callTool({name:'notebook_import_program',arguments:{op:'status',packageHash:descriptor.packageHash}}));
  }
  signal?.throwIfAborted();
  if(result.status!=='ready')throw Error('Program import: '+JSON.stringify(result));
  return result;
}

export async function readInput(path,maxBytes=32*1024*1024) {
  const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
  let bytes;
  try {
    const info=await file.stat();if(!info.isFile()||info.size>maxBytes)throw Error('Input must be a bounded regular file');
    bytes=Buffer.alloc(info.size+1);const {bytesRead}=await file.read(bytes,0,bytes.length,0);
    if(bytesRead!==info.size)throw Error('Portable metadata changed during read');bytes=bytes.subarray(0,bytesRead);
  }finally{await file.close();}
  return {bytes,value:JSON.parse(bytes.toString('utf8'))};
}

export async function readPortable(path) {
  const {bytes,value:portable}=await readInput(path,8*1024*1024),{cut,packages}=portable;
  if(portable.format!=='NotebookPortable/1'||!cut?.document||!cut?.state||cut.document.id!==cut.state.id
    ||!Array.isArray(cut.document.blocks)||!Array.isArray(cut.state.records)||!Array.isArray(packages)||packages.length>512)throw Error('Invalid portable document');
  const required=new Set(cut.document.blocks.map(b=>b.programPackage).filter(Boolean)),seen=new Set(),parts=new Map();
  const descriptors=packages.map(({sha256,value})=>{
    if(!hash(sha256)||seen.has(sha256)||!required.has(sha256)||digest(canonicalProgramJSON(value))!==sha256
      ||!Array.isArray(value.files)||value.files.length>4096)throw Error('Portable package identity mismatch');
    seen.add(sha256);
    return {packageHash:sha256,package:value,sources:value.files.map(file=>{
      if(!validProgramPath(file.path)||!Array.isArray(file.parts))throw Error('Invalid portable file');
      let size=0;
      const partPaths=file.parts.map(part=>{
        if(!hash(part.sha256)||!Number.isSafeInteger(part.byteCount)||part.byteCount<=0||part.byteCount>partBytes
          ||(parts.has(part.sha256)&&parts.get(part.sha256)!==part.byteCount))throw Error('Invalid portable part');
        size+=part.byteCount;parts.set(part.sha256,part.byteCount);
        return join(dirname(resolve(path)),'blob-'+part.sha256);
      });
      if(size!==file.byteCount)throw Error('Portable file size mismatch');
      return {path:file.path,partPaths};
    })};
  });
  if(seen.size!==required.size||parts.size>16383)throw Error('Incomplete portable package set');
  return {portable,descriptors,sha256:digest(bytes)};
}

const uuid=seed=>{const s=digest(seed);return `${s.slice(0,8)}-${s.slice(8,12)}-5${s.slice(13,16)}-a${s.slice(17,20)}-${s.slice(20,32)}`;};
export function portableRequest({portable,sha256}) {
  const {document,state}=portable.cut,values=new Map(state.records.map(r=>[r.id,r.value]));
  const blocks=document.blocks.map(block=>{
    if(block.kind!=='interactive')return {id:block.id,kind:block.kind,source:block.source};
    const value=Object.fromEntries(['id','kind','html','css','javaScript','height','programPackage'].filter(k=>block[k]!==undefined).map(k=>[k,block[k]]));
    value.initialState=values.has(block.id)?values.get(block.id):block.initialState??null;return value;
  });
  const args={documentID:uuid('document:'+sha256),title:'Импортированный документ',paperSize:document.paperSize,preamble:document.preamble??'',blocks};
  if(Buffer.byteLength(JSON.stringify(args))>1048576)throw Error('Portable document source metadata exceeds the existing 1 MiB transaction input; assets are never embedded');
  return {op:'start',api_version:2,language:'javascript',run_id:uuid('run:'+sha256),wait_ms:1000,args,code:`
    const header=await nb.read({kind:'workspaceHeader'});
    const target={kind:'board',id:header.data.rootBoardID};
    const snapshot=await nb.readMany({queries:[{kind:'workspaceHeader'},{kind:'boardContentRevision',id:target.id}]});
    const action=await nb.transaction('portable-import',{base:snapshot.basis,summary:'Import portable document',additionalOwners:[target],operations:[
      {kind:'createDocument',target,id:args.documentID,values:{title:args.title,paperSize:args.paperSize,preamble:args.preamble,blocks:args.blocks,center:{tileX:0,tileY:0,localX:0,localY:0}}}
    ]});
    return {action,documentID:args.documentID};`};
}

/** One user operation: stage original V2 resources, then one ordinary transaction.
 * No source execution, selection, renderer, npm install or archive restoration. */
export async function submitPortable(client,path,signal) {
  const prepared=await readPortable(path),request=portableRequest(prepared);
  signal?.throwIfAborted();
  const directory=await mkdtemp(join(tmpdir(),'notebook-portable-import-'));
  try {
    for(const [index,descriptor] of prepared.descriptors.entries()) {
      signal?.throwIfAborted();const manifest=join(directory,`${index}.json`);
      await writeFile(manifest,JSON.stringify(descriptor),{mode:0o600});
      await stageProgram(client,descriptor,manifest,signal);
    }
    signal?.throwIfAborted();
    let operation=request,after=0,uncertainStart=false,cancelled=false;
    for(;;) {
      const reply=await client.callTool({name:'notebook_execute',arguments:operation}),result=reply.structuredContent??reply;
      if(result.code==='response_pending') {
        uncertainStart ||= operation.op==='start';
        after=result.after_seq??after;
      } else if(result.code==='run_missing'&&uncertainStart&&after===0&&!signal?.aborted) {
        // The only allowed replay is the identical, stably identified start.
        operation=request;continue;
      } else {
        if(reply.isError)throw Error(JSON.stringify(result));
        after=result.next_seq??after;
        if(!['queued','running'].includes(result.status)&&!result.has_more)return result;
      }
      // Cancellation cannot roll back an already admitted transaction. Native
      // effects decide the winner; drain that same run rather than replaying it.
      const op=signal?.aborted&&!cancelled?'cancel':'resume';cancelled ||= op==='cancel';
      operation={op,run_id:request.run_id,after_seq:after,wait_ms:1000};
    }
  } finally {await rm(directory,{recursive:true,force:true});}
}
