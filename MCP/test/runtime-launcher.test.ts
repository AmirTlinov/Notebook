import assert from 'node:assert/strict';
import {test, type TestContext} from 'node:test';
import {randomUUID} from 'node:crypto';
import {Client, InMemoryTransport} from '@modelcontextprotocol/client';
import {createServer, type Socket} from 'node:net';
import {chmod, cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {ensureRuntime, runtimeBootstrap} from '../src/runtime-launcher.js';
import {createServer as createNotebookServer} from '../src/server.js';
import {BridgeError} from '../src/bridge.js';

const status={kind:'notebookRuntime',ready:true,pid:1234,state:'workspaceRequired',protocolVersion:1,build:'248'};

async function owner(t:TestContext, reply:(request:Record<string,unknown>)=>Record<string,unknown>|null, endpoint?:string) {
  const root=endpoint?dirname(endpoint):await mkdtemp('/tmp/notebook-launch-');
  await chmod(root,0o700);
  const socket=endpoint??join(root,'bridge.sock'), connections=new Set<Socket>();
  const server=createServer({allowHalfOpen:true},connection=>{
    connections.add(connection);connection.once('close',()=>connections.delete(connection));
    let data=Buffer.alloc(0);
    connection.on('data',(chunk:Buffer)=>{
      data=Buffer.concat([data,chunk]);
      if(data.length<4 || data.length<4+data.readUInt32BE(0)) return;
      const envelope=JSON.parse(data.subarray(4).toString('utf8'));
      const response=reply(envelope.request);
      if(response===null){connection.end();return;}
      const body=Buffer.from(JSON.stringify({version:1,id:envelope.id,...response}));
      const length=Buffer.alloc(4);length.writeUInt32BE(body.length);
      // Exercise the existing frame parser across a fragmented prefix.
      connection.write(length.subarray(0,2));
      connection.end(Buffer.concat([length.subarray(2),body]));
    });
  });
  let starting:Promise<void>|undefined;
  const start=()=>starting ??= (async()=>{
    await new Promise<void>((resolve,reject)=>{
      server.once('error',reject);server.listen(socket,resolve);
    });
    await chmod(socket,0o600);
  })();
  const stop=async()=>{
    for(const connection of connections) connection.destroy();
    if(server.listening) await new Promise<void>(resolve=>server.close(()=>resolve()));
    starting=undefined;
  };
  t.after(async()=>{
    await stop();
    if(!endpoint)await rm(root,{recursive:true,force:true});
  });
  return {root,socket,start,stop};
}

test('MCP clients join the ready owner even before a workspace exists',async t=>{
  const host=await owner(t,()=>({result:status}));
  await host.start();
  const launch=async()=>{assert.fail('A live owner must not be launched again');};
  const results=await Promise.all(Array.from({length:4},()=>ensureRuntime('/private/plugin/runtime/NotebookRuntime.app',host.socket,status.build,{launch})));
  assert(results.every(value=>value.pid===status.pid && value.state==='workspaceRequired'));
});

test('cold clients wait for bundled runtime admission on one isolated endpoint',async t=>{
  const host=await owner(t,()=>({result:{...status,state:'opening'}}));
  const app='/private/plugin/runtime/NotebookRuntime.app';
  let launches=0;
  const launch=async(candidate:string)=>{assert.equal(candidate,app);launches++;await host.start();};
  const results=await Promise.all(Array.from({length:3},()=>ensureRuntime(app,host.socket,status.build,{launch})));
  assert(launches>0);assert(results.every(value=>value.pid===status.pid));
  // The native process lease owns duplicate launch admission. The launcher
  // neither takes a second store lock nor terminates the shared owner.
  assert.equal((await ensureRuntime(app,host.socket,status.build,{launch})).pid,status.pid);
});

test('an incompatible or unsafe owner cannot trigger a second runtime',async t=>{
  let response:Record<string,unknown>={error:{code:'invalid_command',message:'Unknown runtimeStatus'}};
  const host=await owner(t,()=>response);
  await host.start();
  const launch=async()=>{assert.fail('Do not launch beside an incompatible owner');};
  await assert.rejects(ensureRuntime('/plugin/NotebookRuntime.app',host.socket,status.build,{launch}),/runtime transition/);
  response={result:{...status,build:'previous'}};
  await assert.rejects(ensureRuntime('/plugin/NotebookRuntime.app',host.socket,status.build,{launch}),/runtime_update_required/);
  response={result:{...status,protocolVersion:2}};
  await assert.rejects(ensureRuntime('/plugin/NotebookRuntime.app',host.socket,status.build,{launch}),/runtime_update_required/);
  await chmod(host.socket,0o666);
  await assert.rejects(ensureRuntime('/plugin/NotebookRuntime.app',host.socket,status.build,{launch}),/0700.*0600/);
});

test('startup timeout is bounded and launches at most once per client',async t=>{
  const host=await owner(t,()=>({result:status}));
  let launches=0;
  await assert.rejects(ensureRuntime('/plugin/NotebookRuntime.app',host.socket,status.build,
    {launch:async()=>{launches++;},timeoutMilliseconds:150}),/has not opened its IPC channel/);
  assert.equal(launches,1);
});

test('a live MCP connection recovers its crashed runtime before an addressed retry without replaying uncertain writes',async t=>{
  const workspaceID=randomUUID(),socketKey='0123456789abcdef01234567';
  const target={kind:'board',id:randomUUID()},address={workspaceID,socketKey,target};
  const edit={...address,actionID:randomUUID(),summary:'Correct text',
    operations:[{kind:'updateElement',target,id:'text',values:{source:'After'}}],
    sources:[{id:'text',spatial:{id:'text',source:'Before',state:null}}]};
  const {socketKey:_socketKey,...domainEdit}=edit;
  const requests:Record<string,unknown>[]=[],writes:Record<string,unknown>[]=[];
  let build=status.build,uncertain=true,launches=0;
  const current=()=>({...status,build,state:'ready',workspaceID,socketKey});
  const runtime=await owner(t,request=>{
    if(request.command==='runtimeStatus')return {result:current()};
    assert.deepEqual(request,{command:'runtimeWorkspace',runtimeWorkspace:{action:'retry',id:workspaceID}});
    requests.push(request);
    return {result:{status:current(),workspaces:[]}};
  });
  const content=await owner(t,request=>{
    if(request.command==='panelRead'){
      assert.equal((request.panelRead as Record<string,unknown>).workspaceID,workspaceID);
      return {result:{...address,cursor:'1'}};
    }
    assert.equal(request.command,'panelEdit');
    writes.push(request.panelEdit as Record<string,unknown>);
    return uncertain?null:{result:{status:'saved',actionID:edit.actionID}};
  },join(runtime.root,`${socketKey}.sock`));
  await Promise.all([runtime.start(),content.start()]);
  const bootstrapRuntime=runtimeBootstrap('/signed/plugin/runtime/NotebookRuntime.app',runtime.socket,status.build,{
    launch:async()=>{launches++;await Promise.all([runtime.start(),content.start()]);},
  });
  await bootstrapRuntime();
  const server=createNotebookServer(runtime.socket,{panelHtml:'<html></html>',bootstrapRuntime:async()=>{
    try{return await bootstrapRuntime();}
    catch(error){
      assert(error instanceof BridgeError);
      // The packaged launcher has its own BridgeError class. Its structured
      // payload must survive that module boundary into the server response.
      throw Object.assign(new Error(error.message),{detail:error.detail});
    }
  }});
  const client=new Client({name:'runtime-recovery',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);await client.connect(clientTransport);
  t.after(async()=>{await client.close();await server.close();});
  const unknown=await client.callTool({name:'notebook_panel_edit',arguments:edit});
  assert.equal(unknown.isError,true);
  assert.deepEqual(writes,[domainEdit],'A missing response does not replay an already sent edit');
  assert.equal(launches,0);
  await Promise.all([runtime.stop(),content.stop()]);
  uncertain=false;
  const recovered=await Promise.all([
    client.callTool({name:'notebook_open',arguments:{}}),
    client.callTool({name:'notebook_panel_workspace',arguments:{action:'retry',id:workspaceID}}),
  ]);
  assert(recovered.every(result=>result.isError!==true));
  assert.equal(launches,1,'Concurrent bootstrap reads share one launch admission');
  assert.equal(requests.length,1,'The addressed workspace command is dispatched exactly once');
  assert.deepEqual(writes,[domainEdit],'Bootstrap recovery cannot replay the uncertain mutation');
  const retried=await client.callTool({name:'notebook_panel_edit',arguments:edit});
  assert.notEqual(retried.isError,true);
  assert.deepEqual(writes,[domainEdit,domainEdit],'The caller retries its unchanged action ID and captured sources explicitly');
  build='incompatible';
  const incompatible=await client.callTool({name:'notebook_panel_workspace',arguments:{action:'retry',id:workspaceID}});
  assert.equal(incompatible.isError,true);
  assert.equal((incompatible.structuredContent as Record<string,unknown>)?.code,'runtime_update_required');
  assert.equal(requests.length,1,'Version refusal happens before the addressed command');
  assert.equal(launches,1,'An incompatible owner cannot be replaced by a second launch');
});

test('runtime staging preserves the previous package until the copied product validates',async t=>{
  const {packageRuntime}=await import(new URL('../package-plugin-runtime.mjs',import.meta.url).href);
  const root=await realpath(await mkdtemp('/tmp/notebook-package-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const plugin=join(root,'plugin'), source=join(root,'signed/NotebookRuntime.app');
  await mkdir(join(plugin,'.codex-plugin'),{recursive:true});
  await writeFile(join(plugin,'.codex-plugin/plugin.json'),JSON.stringify({name:'notebook'}));
  await mkdir(source,{recursive:true});await writeFile(join(source,'sealed'),'new sealed resource');
  const previous=join(plugin,'runtime/NotebookRuntime.app');
  await mkdir(previous,{recursive:true});await writeFile(join(previous,'sealed'),'previous sealed resource');
  const copy=(from:string,to:string)=>cp(from,to,{recursive:true,verbatimSymlinks:true});
  const inspect=async(app:string)=>{
    assert.equal(await readFile(join(app,'sealed'),'utf8'),'new sealed resource');
    return {app,panelReady:true};
  };
  await assert.rejects(packageRuntime(source,plugin,{copy,inspect:async(app:string)=>{
    if(app!==source) throw new Error('copied signature failed');return inspect(app);
  }}),/copied signature failed/);
  assert.equal(await readFile(join(previous,'sealed'),'utf8'),'previous sealed resource');
  const result=await packageRuntime(source,plugin,{copy,inspect});
  assert.equal(result.app,previous);
  assert.equal(await readFile(join(previous,'sealed'),'utf8'),'new sealed resource');
  assert.equal(await readFile(join(source,'sealed'),'utf8'),'new sealed resource');
  assert(!(await readdir(plugin)).some(name=>name.startsWith('.runtime-stage-')));
});
