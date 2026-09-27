import {open} from 'node:fs/promises';
import {constants} from 'node:fs';
import {resolve} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {validProgramPath} from './program-package.mjs';
const response=reply=>{if(reply.isError)throw Error(JSON.stringify(reply));return reply.structuredContent??reply;};
const delay=()=>new Promise(resolve=>setTimeout(resolve,250));

export async function readInput(path,maxBytes=32*1024*1024) {
  const bytes=await readBoundedFile(path,maxBytes);
  return {bytes,value:JSON.parse(bytes.toString('utf8'))};
}

async function readBoundedFile(path,maxBytes) {
  const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
  try {
    const info=await file.stat();
    if(!info.isFile()||info.size>maxBytes)throw Error('Input must be a bounded regular file');
    const bytes=Buffer.alloc(info.size+1);let offset=0;
    while(offset<bytes.length) {
      const {bytesRead}=await file.read(bytes,offset,bytes.length-offset,offset);
      if(!bytesRead)break;offset+=bytesRead;
    }
    const final=await file.stat();
    if(offset!==info.size||final.size!==info.size||final.mtimeMs!==info.mtimeMs)throw Error('Input changed during read');
    return bytes.subarray(0,offset);
  } finally {await file.close();}
}

/** Spatial programs retain their existing immutable package staging owner. */
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

/** No ZIP parser or source converter here: the native owner validates the same
 * bytes named by this digest and performs the one canonical import command. */
export async function documentImportRequest(client,path,signal) {
  signal?.throwIfAborted();
  const bytes=await readBoundedFile(path,64*1024*1024);
  const header=response(await client.callTool({name:'notebook_context',arguments:{method:'read',args:{kind:'workspaceHeader'}}}));
  const targetBoardID=header.value?.data?.rootBoardID;
  if(typeof targetBoardID!=='string')throw Error('Workspace header has no root board');
  return {id:randomUUID(),filePath:resolve(path),sha256:createHash('sha256').update(bytes).digest('hex'),
    targetBoardID,center:{tileX:0,tileY:0,localX:0,localY:0}};
}

export async function submitDocument(client,request,signal) {
  // Every uncertain retry carries the same native import identity. No JS run,
  // staged synthetic package or fallback source transaction is created.
  for(let attempt=0;attempt<3;attempt++) {
    signal?.throwIfAborted();
    const reply=await client.callTool({name:'notebook_import_document',arguments:request});
    const value=reply.structuredContent??reply;
    if(reply.isError&&['ipc_timeout','ipc_unavailable'].includes(value.code)&&attempt<2) {await delay();continue;}
    const result=response(reply);
    if(result.status!=='imported')throw Error('Document import: '+JSON.stringify(result));
    return result;
  }
}

/** The native importer computes the immutable part descriptor; local tooling
 * only names the exact input bytes and their document-relative destination. */
export async function documentResourceRequest(path,documentPath,signal) {
  signal?.throwIfAborted();
  if(!validProgramPath(documentPath))throw Error('Resource path must be relative to the document');
  const bytes=await readBoundedFile(path,16*1024*1024);
  return {filePath:resolve(path),path:documentPath,sha256:createHash('sha256').update(bytes).digest('hex')};
}

export async function submitDocumentResource(client,request,signal) {
  for(let attempt=0;attempt<3;attempt++) {
    signal?.throwIfAborted();
    const reply=await client.callTool({name:'notebook_import_document_resource',arguments:request});
    const value=reply.structuredContent??reply;
    if(reply.isError&&['ipc_timeout','ipc_unavailable','document_resource_busy'].includes(value.code)&&attempt<2) {await delay();continue;}
    const result=response(reply);
    if(result.status!=='ready')throw Error('Document resource import: '+JSON.stringify(result));
    return result;
  }
}
