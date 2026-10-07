import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm,symlink,open,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {createServer as createSocketServer} from 'node:net';
import {Client,InMemoryTransport} from '@modelcontextprotocol/client';
import {createServer} from './panel-fixture.js';
// @ts-expect-error Executable file transport is plain JavaScript.
import {documentImportRequest,submitDocument,documentResourceRequest,submitDocumentResource} from '../skills/notebook/scripts/file-import.mjs';
// @ts-expect-error Executable local preparation is plain JavaScript.
import {prepare} from '../skills/notebook/scripts/prepare.mjs';
const boardID=randomUUID();
async function fixture(t:any){
  const root=await mkdtemp(join(tmpdir(),'document-import-test-'));t.after(()=>rm(root,{recursive:true,force:true}));
  const bytes=Buffer.from('PK\x03\x04 Native ZIP validation owns these opaque bytes. throw Error("must not execute")');
  const path=join(root,'book.notex');await writeFile(path,bytes);
  return {root,path,bytes};
}
const header={structuredContent:{status:'ready',value:{data:{rootBoardID:boardID}}}};

test('portable document transport forwards one exact opaque file to the native importer',async t=>{
  const f=await fixture(t),calls:any[]=[];
  const client={callTool:async(call:any)=>{
    calls.push(call);
    if(call.name==='notebook_context')return header;
    assert.equal(call.name,'notebook_import_document');
    return {structuredContent:{status:'imported',documentID:randomUUID(),actionID:call.arguments.id,cachedPrint:false}};
  }};
  const request=await documentImportRequest(client,f.path),result=await submitDocument(client,request);
  assert.equal(request.filePath,f.path);assert.equal(request.sha256,createHash('sha256').update(f.bytes).digest('hex'));
  assert.equal(request.targetBoardID,boardID);assert.equal(result.actionID,request.id);
  assert.deepEqual(calls.map(call=>call.name),['notebook_context','notebook_import_document']);
  assert.deepEqual(calls[0].arguments,{method:'read',args:{kind:'workspaceHeader'}});
  assert.deepEqual(calls[1].arguments,request);assert.ok(!('source' in request));
  const another=await documentImportRequest(client,f.path);assert.notEqual(another.id,request.id,'A later explicit import creates another copy');
});

test('uncertain native response retries the same request; validation failures and cancellation do not retry',async t=>{
  const f=await fixture(t),request=await documentImportRequest({callTool:async()=>header},f.path),calls:any[]=[];
  const client={callTool:async(call:any)=>{
    calls.push(call);
    return calls.length<3?{isError:true,structuredContent:{status:'error',code:'ipc_timeout'}}
      :{structuredContent:{status:'imported',documentID:randomUUID(),actionID:request.id,cachedPrint:true}};
  }};
  assert.equal((await submitDocument(client,request)).cachedPrint,true);
  assert.equal(calls.length,3);assert.ok(calls.every(call=>JSON.stringify(call.arguments)===JSON.stringify(request)));
  let failures=0;
  await assert.rejects(submitDocument({callTool:async()=>{failures++;return {isError:true,structuredContent:{code:'invalid_package'}};}},request),/invalid_package/);
  assert.equal(failures,1);
  const abort=new AbortController();abort.abort();await assert.rejects(submitDocument(client,request,abort.signal));assert.equal(calls.length,3);
});

test('document file admission rejects symlinks and oversized input without any native call',async t=>{
  const f=await fixture(t),link=join(f.root,'linked.notex');await symlink(f.path,link);
  let calls=0;const client={callTool:async()=>{calls++;return header;}};
  await assert.rejects(documentImportRequest(client,link));
  const huge=join(f.root,'large.notex'),file=await open(huge,'w');await file.truncate(64*1024*1024+1);await file.close();
  await assert.rejects(documentImportRequest(client,huge),/bounded regular file/);assert.equal(calls,0);
});

test('document import MCP capability forwards only the typed native request',async t=>{
  const f=await fixture(t),socketPath=join(f.root,'bridge.sock'),requests:any[]=[];
  const native=createSocketServer(socket=>{
    let bytes=Buffer.alloc(0);
    socket.on('data',part=>{
      bytes=Buffer.concat([bytes,Buffer.isBuffer(part)?part:Buffer.from(part)]);
      if(bytes.length<4||bytes.length<4+bytes.readUInt32BE(0))return;
      const envelope=JSON.parse(bytes.subarray(4).toString());requests.push(envelope.request);
      const result=envelope.request.command==='importDocumentResource'?{status:'ready',sha256:envelope.request.documentResourceImport.sha256,resource:{path:'figures/chart.png',mimeType:'image/png',byteCount:6,parts:[{sha256:'a'.repeat(64),byteCount:6}]}}:{status:'imported',documentID:randomUUID(),actionID:envelope.request.documentImport.id,cachedPrint:false};
      const body=Buffer.from(JSON.stringify({version:1,id:envelope.id,result})),length=Buffer.alloc(4);length.writeUInt32BE(body.length);
      socket.end(Buffer.concat([length,body]));
    });
  });
  const server=createServer(socketPath),client=new Client({name:'document-import-contract',version:'1'});
  try {
    await chmod(f.root,0o700);await new Promise<void>(resolve=>native.listen(socketPath,resolve));await chmod(socketPath,0o600);
    const [c,s]=InMemoryTransport.createLinkedPair();await server.connect(s);await client.connect(c);
    const request={id:randomUUID(),filePath:f.path,sha256:'a'.repeat(64),targetBoardID:boardID,center:{tileX:0,tileY:0,localX:0,localY:0}};
    const result=await client.callTool({name:'notebook_import_document',arguments:request});assert.notEqual(result.isError,true);
    assert.deepEqual(requests,[{command:'importDocument',documentImport:request}]);
    const refused=await client.callTool({name:'notebook_import_document',arguments:{...request,filePath:'relative.notex'}});
    assert.equal(refused.isError,true);assert.equal(requests.length,1);
    const resource={filePath:f.path,path:'figures/chart.png',sha256:'a'.repeat(64)};
    const staged=await client.callTool({name:'notebook_import_document_resource',arguments:resource});assert.notEqual(staged.isError,true);
    assert.deepEqual(requests[1],{command:'importDocumentResource',documentResourceImport:resource});
    assert.equal((await client.callTool({name:'notebook_import_document_resource',arguments:{...resource,path:'../chart.png'}})).isError,true);
    assert.equal(requests.length,2);
  } finally {await client.close();await server.close();native.close();}
});


test('resource-only preparation hashes bytes, retries immutable staging and never makes a program or document',async t=>{
  const f=await fixture(t),bytes=Buffer.from([137,80,78,71,0,255]),path=join(f.root,'chart.png');await writeFile(path,bytes);
  const request=await documentResourceRequest(path,'figures/chart.png');
  assert.deepEqual(request,{filePath:path,path:'figures/chart.png',sha256:createHash('sha256').update(bytes).digest('hex')});
  const prepared=await prepare('document-resource',{sourcePath:'chart.png',path:'figures/chart.png'},{baseDirectory:f.root});
  assert.deepEqual(prepared,{tool:'notebook_import_document_resource',arguments:request});
  const calls:any[]=[],resource={path:request.path,mimeType:'image/png',byteCount:bytes.length,parts:[{sha256:request.sha256,byteCount:bytes.length}]};
  const client={callTool:async(call:any)=>{calls.push(call);return calls.length===1?{isError:true,structuredContent:{code:'ipc_timeout'}}:{structuredContent:{status:'ready',sha256:request.sha256,resource}};}};
  assert.deepEqual((await submitDocumentResource(client,request)).resource,resource);
  assert.equal(calls.length,2);assert.ok(calls.every(call=>call.name==='notebook_import_document_resource'&&JSON.stringify(call.arguments)===JSON.stringify(request)));
  const link=join(f.root,'linked.png');await symlink(path,link);await assert.rejects(documentResourceRequest(link,request.path));
  await assert.rejects(documentResourceRequest(path,'../chart.png'),/relative/);
  const huge=join(f.root,'large.png'),file=await open(huge,'w');await file.truncate(16*1024*1024+1);await file.close();
  await assert.rejects(documentResourceRequest(huge,request.path),/bounded regular file/);
  assert.ok(!('source' in prepared)&&!('package' in prepared)&&!('run_id' in prepared));
});
