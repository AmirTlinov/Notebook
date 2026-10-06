import assert from 'node:assert/strict';
import test from 'node:test';
import {chmod,mkdtemp,rm} from 'node:fs/promises';
import {createServer,type Socket} from 'node:net';
import {join} from 'node:path';
import {Client,InMemoryTransport} from '@modelcontextprotocol/client';
import {createServer as createNotebookServer} from '../src/server.js';
import {BridgeError,runBridge} from '../src/bridge.js';

type Value=Record<string,unknown>;
function event<T>(){let resolve!:(value:T)=>void;return {promise:new Promise<T>(done=>{resolve=done;}),resolve:(value:T)=>resolve(value)};}
async function endpoint(){
  const directory=await mkdtemp('/tmp/nb-abort-');await chmod(directory,0o700);
  const socketPath=join(directory,'0123456789abcdef01234567.sock'),sockets=new Set<Socket>();
  let accepted=0;
  const requested=event<{socket:Socket;id:string;request:Value}>(),disconnected=event<void>(),halfClosed=event<void>();
  const server=createServer({allowHalfOpen:true},socket=>{
    accepted++;sockets.add(socket);
    const buffers:Buffer[]=[];let bytes=0,size:number|undefined;
    socket.on('data',chunk=>{
      const part=typeof chunk==='string'?Buffer.from(chunk):chunk;
      buffers.push(part);bytes+=part.length;
      const frame=Buffer.concat(buffers);
      if(size===undefined&&bytes>=4)size=frame.readUInt32BE(0);
      if(size!==undefined&&bytes===size+4){
        const value=JSON.parse(frame.subarray(4).toString()) as {id:string;request:Value};requested.resolve({socket,...value});
      }
    });
    socket.on('end',()=>halfClosed.resolve());
    socket.on('close',()=>{sockets.delete(socket);disconnected.resolve();});
    socket.on('error',()=>{});
  });
  await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(socketPath,resolve)});await chmod(socketPath,0o600);
  return {socketPath,requested,halfClosed,disconnected,get accepted(){return accepted},
    async close(){for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>server.close(()=>resolve()));await rm(directory,{recursive:true,force:true})}};
}
function reply(socket:Socket,id:string,value:Value){
  const body=Buffer.from(JSON.stringify({version:1,id,result:value})),header=Buffer.alloc(4);header.writeUInt32BE(body.length);
  socket.end(Buffer.concat([header,body]));
}

test('bridge abort before admission never connects and disposes its timer/listener',async t=>{
  const native=await endpoint();t.after(()=>native.close());
  const controller=new AbortController();controller.abort();
  await assert.rejects(runBridge(native.socketPath,{command:'read'},{signal:controller.signal}),
    (error:unknown)=>error instanceof BridgeError&&error.detail.code==='ipc_cancelled');
  assert.equal(native.accepted,0);
});

test('healthy write-half-close still receives the exact native response',async t=>{
  const native=await endpoint();t.after(()=>native.close());
  const controller=new AbortController(),result=runBridge(native.socketPath,{command:'read'},{signal:controller.signal});
  const request=await native.requested.promise;await native.halfClosed.promise;
  assert.equal(request.socket.destroyed,false,'socket.end(frame) closes only the request direction');
  reply(request.socket,request.id,{cursor:'7'});
  assert.deepEqual(await result,{cursor:'7'});
  controller.abort(); // A completed bridge has removed its caller listener.
});

test('caller abort and shared deadline retire only their actual socket',async t=>{
  for(const reason of ['abort','deadline'] as const)await t.test(reason,async t=>{
    const native=await endpoint();t.after(()=>native.close());
    const controller=new AbortController(),deadline=performance.now()+(reason==='deadline'?500:5000);
    const result=runBridge(native.socketPath,{command:'read'},{deadline,signal:controller.signal});
    const refused=assert.rejects(result,(error:unknown)=>error instanceof BridgeError
      &&error.detail.code===(reason==='deadline'?'ipc_timeout':'ipc_cancelled'));
    const request=await native.requested.promise;
    if(reason==='abort')controller.abort();
    await refused;
    // After a legal write-half-close, Node's readable direction is already
    // ended. Attempting this late response observes the disconnected reader.
    request.socket.end(Buffer.from('late response'));
    await native.disconnected.promise;
    assert.equal(request.socket.destroyed,true);
    assert.equal(native.accepted,1,'An abandoned request is never replayed');
  });
});

test('MCP sender cancellation reaches the existing native panel request without replay',async t=>{
  const native=await endpoint();t.after(()=>native.close());
  const server=createNotebookServer(native.socketPath,{panelHtml:'<html>isolated panel</html>'});
  const client=new Client({name:'abort-probe',version:'1'}),[caller,owner]=InMemoryTransport.createLinkedPair();
  await server.connect(owner);await client.connect(caller);t.after(async()=>{await client.close();await server.close()});
  const controller=new AbortController();
  const result=client.callTool({name:'notebook_panel_presentation',arguments:{
    workspaceID:'00000000-0000-4000-8000-000000000001',target:{kind:'board',id:'00000000-0000-4000-8000-000000000002'},
    socketKey:'0123456789abcdef01234567',appearance:{viewport:{x:800,y:600},pixelScale:1}}},{signal:controller.signal});
  // The public panel owns an admitted endpoint. This fixture names the actual
  // endpoint's socketKey rather than relying on another window's selection.
  const refused=assert.rejects(result);
  const request=await native.requested.promise;
  assert.equal(request.request.command,'panelPresentation');
  controller.abort();await refused;
  // Wait for the SDK cancellation callback to retire the real bridge before
  // observing the late response on the peer's already ended read direction.
  await new Promise<void>(resolve=>setImmediate(resolve));
  request.socket.end(Buffer.from('late response'));await native.disconnected.promise;
  assert.equal(native.accepted,1);
});
