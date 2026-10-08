import assert from 'node:assert/strict';
import {test, type TestContext} from 'node:test';
import {randomUUID} from 'node:crypto';
import {Client, InMemoryTransport} from '@modelcontextprotocol/client';
import {createServer, type Socket} from 'node:net';
import {chmod, link, lstat, mkdtemp, rm, unlink} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {ensureRuntime, runtimeBootstrap, type RuntimeStartupEvent} from '../src/runtime-launcher.js';
import {createServer as createNotebookServer} from '../src/server.js';
import {BridgeError} from '../src/bridge.js';
import {runtimeAdmission} from '../src/runtime-admission.js';

function callTool(client:Client,...[input,...rest]:Parameters<Client['callTool']>){
  return client.callTool(input,...rest);
}

const status={kind:'notebookRuntime',ready:true,pid:1234,state:'workspaceRequired',protocolVersion:1,build:'248'};

async function owner(t:TestContext, reply:(request:Record<string,unknown>, connection:Socket)=>Record<string,unknown>|null|undefined, endpoint?:string) {
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
      const response=reply(envelope.request,connection);
      if(response===undefined)return;
      if(response===null){connection.end();return;}
      const body=Buffer.from(JSON.stringify({version:1,id:envelope.id,...response}));
      const length=Buffer.alloc(4);length.writeUInt32BE(body.length);
      // Exercise the existing frame parser across a fragmented prefix.
      connection.write(length.subarray(0,2));
      connection.end(Buffer.concat([length.subarray(2),body]));
    });
  });
  let starting:Promise<void>|undefined;
  let identity:{dev:number;ino:number}|undefined;
  const removeOwned=async(path:string,owned:NonNullable<typeof identity>)=>{
    const entry=await lstat(path).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
    if(entry?.isSocket()&&entry.dev===owned.dev&&entry.ino===owned.ino)await unlink(path);
  };
  const start=()=>starting ??= (async()=>{
    const binding=join(root,`.${randomUUID()}`);
    let prepared:typeof identity=undefined;
    try{
      await new Promise<void>((resolve,reject)=>{
        server.once('error',reject);server.listen(binding,resolve);
      });
      await chmod(binding,0o600);prepared=await lstat(binding);
      // link publishes the listening inode exclusively; a competing endpoint
      // is preserved. The strict client never sees its pre-chmod binding.
      await link(binding,socket);identity=prepared;
    }catch(error){
      if(server.listening)await new Promise<void>(resolve=>server.close(()=>resolve()));
      throw error;
    }finally{if(prepared)await removeOwned(binding,prepared);}
  })();
  const stop=async()=>{
    for(const connection of connections) connection.destroy();
    if(server.listening) await new Promise<void>(resolve=>server.close(()=>resolve()));
    if(identity)await removeOwned(socket,identity);identity=undefined;
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
  const results=await Promise.all(Array.from({length:4},()=>ensureRuntime('/private/runtime/NotebookRuntime.app',host.socket,status.build,{launch})));
  assert(results.every(value=>value.pid===status.pid && value.state==='workspaceRequired'));
});

test('cold clients wait for bundled runtime admission on one isolated endpoint',async t=>{
  const host=await owner(t,()=>({result:{...status,state:'opening'}}));
  const app='/private/runtime/NotebookRuntime.app';
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
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,{launch}),/runtime transition/);
  response={result:{...status,build:'previous'}};
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,{launch}),
    /runtime_update_required.*Install the matching Notebook iPad\/runtime pair/);
  response={result:{...status,build:'259'}};
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,'258',{launch}),(error:BridgeError)=>{
    assert.equal(error.detail.code,'runtime_update_required');
    assert.match(error.message,/Reconnect the Notebook MCP server to load build 259/);
    assert.match(error.message,/runtime is already updated/);return true;
  });
  response={result:{...status,protocolVersion:2}};
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,{launch}),
    /runtime_update_required.*Install the matching Notebook iPad\/runtime pair/);
  await chmod(host.socket,0o666);
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,{launch}),/0700.*0600/);
});

test('startup timeout is bounded and launches at most once per client',async t=>{
  const host=await owner(t,()=>({result:status}));
  let launches=0;const events:RuntimeStartupEvent[]=[];
  await assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,
    {launch:async()=>{launches++;},timeoutMilliseconds:150,trace:event=>events.push(event)}),(error:Error)=>{
    assert.match(error.message,/has not opened its IPC channel.*Last attempt: ipc_unavailable/);
    assert(error.cause instanceof BridgeError);assert.equal(error.cause.detail.code,'ipc_unavailable');return true;
  });
  assert.equal(launches,1);
  assert.deepEqual(events.map(value=>value.phase),['startup.begin','launch.begin','launch.end','startup.failed']);
  assert(events.at(-1)!.attempts>=1);assert.equal(events.at(-1)!.lastErrorCode,'ipc_unavailable');
});

test('startup summary counts retries without logging successful polls or private reply fields',async t=>{
  let polls=0;const events:RuntimeStartupEvent[]=[];
  const secret='private-reply-do-not-log';
  const host=await owner(t,()=>++polls<3
    ?{error:{code:'owner_unavailable',message:'Runtime is draining accepted work.',privateReply:secret}}
    :{result:{...status,state:'opening',privateReply:secret}});
  await host.start();
  const result=await ensureRuntime('/private/runtime/NotebookRuntime.app',host.socket,status.build,
    {launch:async()=>assert.fail('An existing owner remains admitted'),trace:event=>events.push(event)});
  assert.equal(result.state,'opening','Trace preserves the existing opening-owner admission contract');
  assert.deepEqual(events.map(value=>value.phase),['startup.begin','startup.done']);
  assert.equal(events[1]!.attempts,3);assert.equal(events[1]!.lastErrorCode,'owner_unavailable');
  assert.equal(events[1]!.runtimePID,status.pid);assert.equal(events[1]!.runtimeState,'opening');
  assert(Number.isFinite(Date.parse(events[0]!.startedAt)));assert.equal(events[1]!.startedAt,events[0]!.startedAt);
  assert(events[1]!.elapsedMilliseconds>=events[0]!.elapsedMilliseconds);
  const serialized=JSON.stringify(events);
  for(const privateValue of [secret,host.socket,'/private/runtime'])assert(!serialized.includes(privateValue));
});

test('timeout retains the last owner refusal without tracing its message or private context',async t=>{
  const detail={code:'owner_unavailable',message:'Runtime is draining accepted work.',privateReply:'private-owner-context'};
  let elapsed=0,polls=0;
  t.mock.method(performance,'now',()=>elapsed);
  t.mock.timers.enable({apis:['setTimeout']});
  let firstClosed!:()=>void,heldRequest!:()=>void;
  const refused=new Promise<void>(resolve=>{firstClosed=resolve;}),held=new Promise<void>(resolve=>{heldRequest=resolve;});
  const host=await owner(t,(request,connection)=>{
    assert.deepEqual(request,{command:'runtimeStatus'});
    if(++polls===1){connection.once('close',firstClosed);return {error:detail};}
    heldRequest();return undefined;
  }),events:RuntimeStartupEvent[]=[];
  await host.start();
  const rejected=assert.rejects(ensureRuntime('/runtime/NotebookRuntime.app',host.socket,status.build,
    {timeoutMilliseconds:150,launch:async()=>assert.fail('No second owner'),trace:event=>events.push(event)}),(error:Error)=>{
    assert.match(error.message,/Last observed owner refusal: owner_unavailable: Runtime is draining accepted work/);
    assert.match(error.message,/Last attempt: ipc_timeout\./);
    assert(!error.message.includes(detail.privateReply));
    assert(error.cause instanceof BridgeError);assert.deepEqual(error.cause.detail,detail);return true;
  });
  // Socket closure follows the parsed first reply. Advance only the existing
  // retry/deadline timers; permission checks, framing and both IPC calls are real.
  await refused;
  elapsed=100;t.mock.timers.tick(100);
  await held;
  elapsed=150;t.mock.timers.tick(50);
  await rejected;
  assert.equal(polls,2);
  assert.deepEqual(events.map(value=>value.phase),['startup.begin','startup.failed']);
  assert.equal(events[1]!.attempts,2);assert.equal(events[1]!.elapsedMilliseconds,150);
  assert.equal(events[1]!.lastErrorCode,'ipc_timeout');assert.equal(events[1]!.lastOwnerRefusalCode,detail.code);
  assert(!JSON.stringify(events).includes(detail.privateReply));assert(!JSON.stringify(events).includes(detail.message));
});

test('a live MCP connection recovers its crashed runtime before an addressed retry without replaying uncertain writes',async t=>{
  const workspaceID=randomUUID(),runID=randomUUID();
  const call={name:'notebook_execute',arguments:{op:'start',run_id:runID,api_version:2,code:'return await nb.transaction(args);',args:{key:randomUUID()},wait_ms:0}};
  const script={op:'start',runID,apiVersion:2,afterSequence:0,waitMilliseconds:0,language:'javascript',
    code:call.arguments.code,arguments:call.arguments.args};
  const requests:Record<string,unknown>[]=[],writes:Record<string,unknown>[]=[];
  let build=status.build,uncertain=true,launches=0;
  const current=()=>({...status,build,state:'ready'});
  const runtime=await owner(t,request=>{
    if(request.command==='runtimeStatus')return {result:current()};
    if(request.command==='script'){
      writes.push(request.script as Record<string,unknown>);
      return uncertain?null:{result:{api_version:2,run_api_version:2,status:'completed',run_id:runID,fingerprint:'fixture',
        events:[],next_seq:0,has_more:false,result:null,error:null,effects:[],resume_semantics:'attach_only_no_replay'}};
    }
    if(request.command==='scriptContext')return {result:{api_version:2,value:{data:{saved:true}}}};
    assert.deepEqual(request,{command:'runtimeWorkspace',runtimeWorkspace:{action:'retry',id:workspaceID}});
    requests.push(request);
    return {result:{status:current(),workspaces:[]}};
  });
  await runtime.start();
  const bootstrapRuntime=runtimeBootstrap('/signed/runtime/NotebookRuntime.app',runtime.socket,status.build,{
    launch:async()=>{launches++;await runtime.start();},
  });
  await bootstrapRuntime();
  const server=createNotebookServer(runtime.socket,{bootstrapRuntime:async()=>{
    try{return await bootstrapRuntime();}
    catch(error){
      assert(error instanceof BridgeError);
      // The bundled launcher has its own BridgeError class. Its structured
      // payload must survive that module boundary into the server response.
      throw Object.assign(new Error(error.message),{detail:error.detail});
    }
  }});
  const client=new Client({name:'runtime-recovery',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);await client.connect(clientTransport);
  t.after(async()=>{await client.close();await server.close();});
  const unknown=await callTool(client,call);
  assert.equal(unknown.isError,true);
  assert.deepEqual(writes,[script],'A missing response does not replay an already sent program');
  assert.equal(launches,0);
  await runtime.stop();uncertain=false;
  const recovered=await Promise.all([
    callTool(client,{name:'notebook_context',arguments:{method:'help'}}),
    callTool(client,{name:'notebook_workspaces',arguments:{action:'retry',id:workspaceID}}),
  ]);
  assert(recovered.every(result=>result.isError!==true));
  assert.equal(launches,1,'Concurrent bootstrap reads share one launch admission');
  assert.equal(requests.length,1,'The addressed workspace command is dispatched exactly once');
  assert.deepEqual(writes,[script],'Bootstrap recovery cannot replay the uncertain mutation');
  const retried=await callTool(client,call);
  assert.notEqual(retried.isError,true);
  assert.deepEqual(writes,[script,script],'The caller explicitly retries its unchanged run, code and arguments');
  build='incompatible';
  const incompatible=await callTool(client,{name:'notebook_workspaces',arguments:{action:'retry',id:workspaceID}});
  assert.equal(incompatible.isError,true);
  assert.equal((incompatible.structuredContent as Record<string,unknown>)?.code,'runtime_update_required');
  assert.equal(requests.length,1,'Version refusal happens before the addressed command');
  assert.equal(launches,1,'An incompatible owner cannot be replaced by a second launch');
});

test('one pending bootstrap leaves MCP handshake and discovery available without dispatching domain calls',async t=>{
  const commands:string[]=[];
  const runtime=await owner(t,request=>{
    if(request.command==='runtimeStatus')return {result:status};
    commands.push(String(request.command));
    return request.command==='runtimeWorkspace'?{result:{status,workspaces:[]}}
      :{result:{api_version:2,value:{data:{saved:true}}}};
  });
  let release!:()=>void,launched!:()=>void,launches=0;
  const held=new Promise<void>(resolve=>{release=resolve;}),started=new Promise<void>(resolve=>{launched=resolve;});
  const bootstrapRuntime=runtimeBootstrap('/isolated/NotebookRuntime.app',runtime.socket,status.build,{
    launch:async()=>{launches++;launched();await held;await runtime.start();},
  });
  const background=bootstrapRuntime();await started;
  const server=createNotebookServer(runtime.socket,{bootstrapRuntime});
  const client=new Client({name:'early-handshake',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  t.after(async()=>{release();await background;await client.close();await server.close();});
  await server.connect(serverTransport);await client.connect(clientTransport);
  const listed=await client.listTools();
  assert(listed.tools.some(tool=>tool.name==='notebook_workspaces'));
  assert(!listed.tools.some(tool=>tool.name==='notebook_open'||tool.name.startsWith('notebook_panel_')));
  assert.deepEqual(commands,[]);
  const reads=Promise.all([callTool(client,{name:'notebook_context',arguments:{method:'help'}}),
    callTool(client,{name:'notebook_workspaces',arguments:{action:'list'}})]);
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.deepEqual(commands,[],'No domain read is sent while bootstrap is pending');
  assert.equal(launches,1);
  release();await background;
  assert((await reads).every(reply=>reply.isError!==true));
  assert.deepEqual(commands.sort(),['runtimeWorkspace','scriptContext']);
  assert.equal(launches,1,'Background and tool callers join one admission attempt');
});

test('workspace-required admission exposes the existing catalog and forwards exact workspace actions',async t=>{
  const id=randomUUID(),requests:Record<string,unknown>[]=[];
  const catalog=[{id,name:'Work'}];
  const runtime=await owner(t,request=>{
    if(request.command==='runtimeStatus')return {result:status};
    requests.push(request);
    return {result:{status,workspaces:catalog}};
  });await runtime.start();
  const bootstrapRuntime=runtimeBootstrap('/isolated/NotebookRuntime.app',runtime.socket,status.build,
    {launch:async()=>assert.fail('workspaceRequired already has an admitted owner')});
  const server=createNotebookServer(runtime.socket,{bootstrapRuntime});
  const client=new Client({name:'workspace-management',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);await client.connect(clientTransport);
  t.after(async()=>{await client.close();await server.close();});
  const actions=[{action:'list'},{action:'create',id,name:'Work'},{action:'select',id},
    {action:'rename',id,name:'Renamed'},{action:'retry',id}];
  for(const action of actions){
    const reply=await callTool(client,{name:'notebook_workspaces',arguments:action});
    assert.notEqual(reply.isError,true);
    assert.deepEqual(reply.structuredContent,{status,workspaces:catalog});
  }
  assert.deepEqual(requests,actions.map(runtimeWorkspace=>({command:'runtimeWorkspace',runtimeWorkspace})));
});

test('an agent deadline expires before admission without a late write, and the same MCP connection can retry',async t=>{
  const runID=randomUUID(),writes:Record<string,unknown>[]=[];
  const runtime=await owner(t,request=>{
    if(request.command==='runtimeStatus')return {result:status};
    writes.push(request);
    return {result:{api_version:2,run_api_version:2,status:'completed',run_id:runID,fingerprint:'fixture',
      events:[],next_seq:0,has_more:false,result:null,error:null,effects:[],resume_semantics:'attach_only_no_replay'}};
  });
  let release!:()=>void,launched!:()=>void;
  const held=new Promise<void>(resolve=>{release=resolve;}),started=new Promise<void>(resolve=>{launched=resolve;});
  const bootstrapRuntime=runtimeBootstrap('/isolated/NotebookRuntime.app',runtime.socket,status.build,{
    launch:async()=>{launched();await held;await runtime.start();},
  });
  const background=bootstrapRuntime();await started;
  const server=createNotebookServer(runtime.socket,{bootstrapRuntime});
  const client=new Client({name:'admission-deadline',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);await client.connect(clientTransport);
  t.after(async()=>{release();await background;await client.close();await server.close();});
  const call={name:'notebook_execute',arguments:{op:'start',run_id:runID,api_version:2,code:'return 1;',wait_ms:0}};
  const began=performance.now(),expired=await callTool(client,call);
  assert.equal(expired.isError,true);
  assert.equal((expired.structuredContent as Record<string,unknown>).code,'runtime_starting');
  assert.equal((expired.structuredContent as Record<string,unknown>).run_id,runID);
  assert(performance.now()-began<5_000,'Admission shares the 3.9 s agent budget instead of waiting for 10 s startup');
  assert.deepEqual(writes,[]);
  release();await background;await new Promise<void>(resolve=>setImmediate(resolve));
  assert.deepEqual(writes,[],'Late admission cannot dispatch the expired call');
  const retried=await callTool(client,call);
  assert.notEqual(retried.isError,true);
  assert.equal(writes.length,1,'Only the explicit retry sends the unchanged run');
});

test('every native tool refuses a mismatched owner before dispatch',async t=>{
  const target={kind:'board',id:randomUUID()},center={tileX:0,tileY:0,localX:0,localY:0};
  const commands:Record<string,unknown>[]=[];
  const runtime=await owner(t,request=>{commands.push(request);return {result:{}};});await runtime.start();
  let admissions=0;
  const server=createNotebookServer(runtime.socket,{bootstrapRuntime:async()=>{
    admissions++;
    throw Object.assign(new Error('Different runtime build'),{detail:{code:'runtime_update_required',message:'Different runtime build'}});
  }});
  const client=new Client({name:'all-admission-gates',version:'1'});
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);await client.connect(clientTransport);
  t.after(async()=>{await client.close();await server.close();});
  const calls=[
    {name:'notebook_import_program',arguments:{op:'status',packageHash:'a'.repeat(64)}},
    {name:'notebook_import_document',arguments:{id:randomUUID(),filePath:'/tmp/document.notex',sha256:'a'.repeat(64),targetBoardID:target.id,center}},
    {name:'notebook_import_document_resource',arguments:{filePath:'/tmp/figure.svg',path:'figure.svg',sha256:'a'.repeat(64)}},
    {name:'notebook_context',arguments:{method:'help'}},
    {name:'notebook_execute',arguments:{op:'start',run_id:randomUUID(),api_version:2,code:'return 1;'}},
    {name:'notebook_workspaces',arguments:{action:'select',id:randomUUID()}},
  ];
  for(const call of calls){
    const result=await callTool(client,call);
    assert.equal(result.isError,true,call.name);
    assert.equal((result.structuredContent as Record<string,unknown>).code,'runtime_update_required',call.name);
  }
  assert.equal(admissions,calls.length);assert.deepEqual(commands,[]);
});

test('a real rejected bootstrap stays recoverable before and after a caller stops waiting',async t=>{
  for(const stoppedWaiting of [false,true])await t.test(stoppedWaiting?'after bounded wait':'before bounded wait',async t=>{
    const id=randomUUID(),request={action:'retry',id},reads:Record<string,unknown>[]=[];
    const runtime=await owner(t,command=>{
      if(command.command==='runtimeStatus')return {result:status};
      reads.push(command);
      return {result:{status,workspaces:[]}};
    });
    let mayStart=false;
    const bootstrapRuntime=runtimeBootstrap('/isolated/NotebookRuntime.app',runtime.socket,status.build,{
      timeoutMilliseconds:150,launch:async()=>{if(mayStart)await runtime.start();},
    });
    const background=bootstrapRuntime().catch(()=>undefined);
    if(stoppedWaiting)await assert.rejects(runtimeAdmission(bootstrapRuntime)(performance.now()+20),
      (error:BridgeError)=>error.detail.code==='runtime_starting');
    const server=createNotebookServer(runtime.socket,{bootstrapRuntime});
    const client=new Client({name:'startup-retry',version:'1'});
    const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);await client.connect(clientTransport);
    t.after(async()=>{await background;await client.close();await server.close();});
    const failed=await callTool(client,{name:'notebook_workspaces',arguments:request});
    assert.equal(failed.isError,true);
    assert.equal((failed.structuredContent as Record<string,unknown>).code,'runtime_startup_failed');
    assert.deepEqual(reads,[]);
    await background;mayStart=true;
    const recovered=await callTool(client,{name:'notebook_workspaces',arguments:request});
    assert.notEqual(recovered.isError,true);
    assert.deepEqual(reads,[{command:'runtimeWorkspace',runtimeWorkspace:request}]);
  });
});
