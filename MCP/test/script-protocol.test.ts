import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {chmod,mkdtemp,readFile,rm} from "node:fs/promises";
import {createServer as createNativeServer} from "node:net";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {Client,InMemoryTransport} from "@modelcontextprotocol/client";
import {createServer,executionOutput} from "../src/server.js";
import {sdkReference} from "../src/sdk-contracts.js";
import {actionSchema,operationSchema} from "../src/actions.js";

test("public SDK help covers every method, all 20 operations, native content and all old capabilities",async()=>{
  const source=await readFile(new URL("../../Sources/NotebookScriptWorker/Resources/notebook-sdk.js",import.meta.url),"utf8");
  const names=[...source.matchAll(/\b([A-Za-z]+):\s*(?:read\(|effect\(|topic\s*=>|key\s*=>|\(key, action\))/g)].map(x=>x[1]!);
  for(const name of [...names,"emit","emitImage"]) {
    const method=sdkReference.methods[name]!;
    assert.ok(method?.input&&method.returns&&method.example,"missing discoverable contract: "+name);
  }
  assert.equal(sdkReference.operations.items.length,20);
  for(const {name,topic} of sdkReference.operations.items) {
    assert.equal(topic,`operation/${name}`);
    assert.ok(sdkReference.operationDetails[name]?.input,"missing operation schema: "+topic);
  }
  assert.match(JSON.stringify(sdkReference.operationDetails.insertElement),/"nativeText"/);
  assert.match(JSON.stringify(sdkReference.operationDetails.insertElement),/"textStyle"/);
  const old=new Set(Object.values(sdkReference.methods).flatMap(value=>value.old??[]));
  assert.equal(old.size,21);
  const bundled=JSON.parse(await readFile(new URL("../../Sources/NotebookScriptHost/Resources/sdk-reference.json",import.meta.url),"utf8"));
  assert.deepEqual(bundled,sdkReference);
});

test("operation discovery is compact and every exact schema reference resolves locally",()=>{
  const bytes=(value:unknown)=>Buffer.byteLength(JSON.stringify(value));
  assert.ok(bytes(sdkReference.operations)<6*1024,"The operation index must not repeat full schemas");
  // New authored radius/longitudinal bend fields bring the shared schema to
  // 24,681 bytes; keep a bounded envelope and verify target reuse directly.
  assert.ok(bytes(sdkReference.methods.transaction)<25*1024,"Atomic action help must remain compact");
  const targetReferences=new Set<string>();
  const collectTargets=(value:any):void=>{
    if(!value||typeof value!=="object")return;
    if(value.properties?.target) {
      assert.ok(value.properties.target.$ref,"Targets must be shared rather than expanded inline");
      targetReferences.add(value.properties.target.$ref);
    }
    for(const child of Object.values(value))collectTargets(child);
  };
  collectTargets(sdkReference.methods.transaction!.input);
  const definitions=(sdkReference.methods.transaction!.input as any).$defs;
  const targetUnions=[...targetReferences].map(ref=>definitions[ref.split("/").at(-1)!]).filter(value=>value.oneOf);
  assert.equal(targetUnions.length,1,"General operations must reuse one physical target union");
  for(const ref of targetReferences) {
    const definition=definitions[ref.split("/").at(-1)!];
    assert.ok(definition.oneOf || targetUnions[0].oneOf.some((member:any)=>member.$ref===ref),
      "A narrower board-only target must reuse the same member of that union");
  }
  for(const {name,input} of Object.values(sdkReference.operationDetails)) {
    assert.ok(bytes(input)<12*1024,`${name} is not a compact individual operation`);
    assert.equal((input as any).properties.kind.const,name);
  }
  const resolve=(root:any,value:any):void=>{
    if(!value||typeof value!=="object")return;
    if(value.$ref) {
      assert.ok(value.$ref.startsWith("#/"),"Help must not require unresolved external schema files");
      let target=root;
      for(const part of value.$ref.slice(2).split("/"))target=target?.[part.replaceAll("~1","/").replaceAll("~0","~")];
      assert.ok(target,"Missing shared schema: "+value.$ref);
    }
    for(const child of Object.values(value))resolve(root,child);
  };
  for(const {input} of [...Object.values(sdkReference.methods),...Object.values(sdkReference.operationDetails)])resolve(input,input);
});

test("individual geometry help constructs an addressed move with source scope and a fresh board revision",async()=>{
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const boardID=randomUUID(),itemID=randomUUID(),calls:any[]=[],actions:any[]=[];
  const detail=sdkReference.operationDetails.moveItem!;
  assert.match(detail.compositionScope!.rule,/contextID.*stored references/);
  assert.match(detail.compositionScope!.owner,/Listing only the board is insufficient/);
  await new AsyncFunction("nb","args","emit",detail.example)({
    board:async(args:unknown)=>{calls.push(args);return {values:[{boardContentRevisions:{[boardID]:"9@human"}}]};},
    transaction:async(key:string,value:unknown)=>{assert.equal(key,"move-item");actions.push(actionSchema.parse(value));return [];},
  },{boardID,itemID},async()=>{});
  assert.deepEqual(calls,[{id:boardID}]);
  assert.deepEqual(actions[0].additionalOwners,[{kind:"cover",id:itemID,boardID}]);
  assert.deepEqual(actions[0].expected,[{target:{kind:"board",id:boardID},revision:"9@human"}]);
  assert.equal(actions[0].operations[0].id,itemID);
  for(const name of ["moveItem","stackItems","updateElement","reorderElements"]) {
    assert.match(sdkReference.operationDetails[name]!.compositionScope!.rule,/additionalOwners/);
  }
  assert.match(sdkReference.execution.effects,/notSaved.*terminal.*without dispatch/);
});

test("rename help discovers its containing board and expects both native owners",async()=>{
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const boardID=randomUUID(),rootBoardID=randomUUID(),itemID=randomUUID(),actor=randomUUID(),actions:any[]=[],reads:any[]=[];
  const detail=sdkReference.operationDetails.renameItem!;
  assert.match(detail.owner!,/containing board/);
  await new AsyncFunction("nb","args","emit",detail.example)({
    read:async(query:unknown)=>{reads.push(query);return {values:[boardID]};},
    board:async(args:unknown)=>{assert.deepEqual(args,{id:boardID});return {values:[{
      header:{rootBoardID,stamp:{counter:8,actor:actor.toUpperCase()}},boardContentRevisions:{[boardID]:"9@human"},
    }]};},
    transaction:async(key:string,value:unknown)=>{assert.equal(key,"rename-item");actions.push(actionSchema.parse(value));return [];},
  },{itemID,title:"Named through public help"},async()=>{});
  assert.deepEqual(reads,[{kind:"ownerBoard",id:itemID}]);
  assert.deepEqual(actions[0].expected,[{target:{kind:"board",id:boardID},revision:"9@human"},
    {target:{kind:"workspace",id:rootBoardID},revision:`8@${actor}`}]);
  const operation=actions[0].operations[0];
  assert.equal(operationSchema.safeParse(operation).success,true);
  assert.equal(operationSchema.safeParse({...operation,target:{kind:"workspace",id:rootBoardID}}).success,false);
});

test("minimal placement example omits optional lists and documents actionable errors and cancellation",async()=>{
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const pageID=randomUUID(),requests:any[]=[];
  await new AsyncFunction("nb","args","emit",sdkReference.methods.place!.example)({
    page:async(args:unknown)=>{assert.deepEqual(args,{id:pageID});return {page:{id:pageID},agentRevision:"4@actor"};},
    place:async(args:unknown)=>{requests.push(args);return {status:"snapshot_pending"};},
  },{pageID},async()=>{});
  assert.deepEqual(requests,[{target:{kind:"page",id:pageID},expectedRevision:"4@actor",
    items:[{id:"next-note",size:{width:180,height:100},direction:"free"}]}]);
  assert.match(sdkReference.execution.operationErrors,/index is zero-based/);
  assert.match(sdkReference.execution.operationErrors,/caught JS error and effects\[\]\.error/);
  assert.match(sdkReference.execution.cancellation,/error.code:'run_cancelled'/);
});

test("document program example installs, declares initial readiness and redraws local and restored state",async()=>{
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const documentID=randomUUID();let action:any;
  await new AsyncFunction("nb","args","emit",sdkReference.examples.interactive)({
    document:async()=>({document:{id:documentID},contentRevision:"7@fixture"}),
    transaction:async(key:string,value:unknown)=>{assert.equal(key,"counter");action=actionSchema.parse(value);return [];},
  },{documentID},async()=>{});
  assert.equal(action.expected[0].target.id,documentID);
  assert.equal(action.expected[0].revision,"7@fixture");
  const block=action.operations[0].values;
  let state=block.initialState,ready:Promise<unknown>|undefined;const commits:unknown[]=[];
  const events:Record<string,()=>void>={},buttonEvents:Record<string,()=>void>={};
  const output={textContent:""},button={addEventListener:(kind:string,handler:()=>void)=>{buttonEvents[kind]=handler;}};
  const document={getElementById:(id:string)=>id==="increment"?button:id==="count"?output:null};
  const notebook={get state(){return state;},commit:(next:unknown)=>{state=next;commits.push(next);return true;},
    ready:(promise:Promise<unknown>)=>{ready=Promise.resolve(promise);return ready;}};
  new Function("document","notebook","addEventListener",block.javaScript)(document,notebook,
    (kind:string,handler:()=>void)=>{events[kind]=handler;});
  assert.ok(ready,"Ready must be declared during installation, before the initial promise settles");
  await ready;assert.equal(output.textContent,"0");
  buttonEvents.click!();assert.deepEqual(commits,[{count:1}]);assert.equal(output.textContent,"1");
  state={count:9};events.notebookstate!();assert.equal(output.textContent,"9");
});

test("documented resume loop waits for a terminal run and drains every remaining event",async()=>{
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const drain=new AsyncFunction("reply","consume","callNotebookExecute",sdkReference.execution.example);
  for(const status of sdkReference.execution.terminalStatuses) {
    const runID=randomUUID(),requests:any[]=[],events:number[]=[];
    const reply=(status:string,sequence:number,has_more:boolean)=>({status,run_id:runID,next_seq:sequence,has_more,
      events:sequence?[{sequence}]:[]});
    const remaining=[reply("running",1,false),reply(status,2,true),reply(status,3,false)];
    const last=await drain(reply("queued",0,false),(event:any)=>events.push(event.sequence),(request:any)=>{
      requests.push(request);assert.ok(remaining.length,"Drain cannot poll after terminal output is exhausted");return remaining.shift();
    });
    assert.equal(last.status,status);assert.equal(last.has_more,false);
    assert.deepEqual(events,[1,2,3]);
    assert.deepEqual(requests.map(r=>[r.op,r.run_id,r.after_seq]),[["resume",runID,0],["resume",runID,1],["resume",runID,2]]);
  }
});

// Synthetic IPC replies isolate SDK output-schema and envelope validation.
// Native writes, receipts and sandboxing are exercised by Core/Mac XPC tests.
test("two-tool MCP preserves attention statuses and exact run identity across start/resume/cancel",async()=>{
  const root=await mkdtemp(join(tmpdir(),"notebook-script-protocol-")),path=join(root,"bridge.sock"),requests:any[]=[];
  let attentionStatus="source_pixels";
  let effects:any[]=[];
  const native=createNativeServer({allowHalfOpen:true},socket=>{
    const chunks:Buffer[]=[];
    socket.on("data",data=>chunks.push(Buffer.from(data)));
    socket.on("end",()=>{
      const packet=JSON.parse(Buffer.concat(chunks).subarray(4).toString()),request=packet.request;
      requests.push(request);
      const result=request.command==="scriptContext"?{status:attentionStatus,reference:{id:randomUUID()},payload:{kind:"fixture"}}
        :{status:request.script.op==="cancel"?"cancelled":"completed",run_id:request.script.runID,
          fingerprint:"a".repeat(64),api_version:1,events:[],next_seq:0,has_more:false,result:42,error:null,
          effects,resume_semantics:"attach_only_no_replay"};
      const payload=attentionStatus==="native_error"?{error:{code:"capture_failed",message:"Source is unavailable",status:"source_pixels"}}:{result};
      const body=Buffer.from(JSON.stringify({version:1,id:packet.id,...payload})),size=Buffer.alloc(4);size.writeUInt32BE(body.length);
      socket.end(Buffer.concat([size,body]));
    });
  });
  const server=createServer(path),client=new Client({name:"script-contract",version:"1"});
  try {
    await chmod(root,0o700);await new Promise<void>(resolve=>native.listen(path,resolve));await chmod(path,0o600);
    const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);await client.connect(clientTransport);
    assert.deepEqual((await client.listTools()).tools.map(t=>t.name).sort(),["notebook_context","notebook_execute"]);
    for(const status of ["source_pixels","source_pixels_unavailable"]) {
      attentionStatus=status;
      const result=await client.callTool({name:"notebook_context",arguments:{method:"attention",args:{contextID:randomUUID(),referenceID:randomUUID()}}});
      assert.notEqual(result.isError,true,JSON.stringify(result));
      assert.equal((result.structuredContent as any).value.status,status);
    }
    const id=randomUUID(),code="return args.answer",args={answer:42};
    for(const op of ["start","resume","cancel"]) {
      const result=await client.callTool({name:"notebook_execute",arguments:{op,run_id:id,
        ...(op==="start"?{api_version:1,code,args}:{})}});
      assert.notEqual(result.isError,true,JSON.stringify(result));
      assert.equal((result.structuredContent as any).run_id,id);
    }
    assert.deepEqual(requests[2],{command:"script",script:{op:"start",runID:id,apiVersion:1,code,arguments:args,afterSequence:0,waitMilliseconds:0}});
    assert.equal(requests[3].script.code,undefined);
    assert.equal(requests[4].script.code,undefined);
    // Shapes observed on the actual v6 blind endpoint: the typed operation
    // diagnostic must cross MCP output validation intact on terminal receipts.
    const operation={index:0,kind:"renameItem",target:{kind:"board",id:randomUUID()},id:randomUUID()};
    const failures=[{code:"revision_required",message:"Для изменения нужна версия владельца.",operation},
      {code:"revision_conflict",message:"Владелец изменился. Прочитайте его текущую версию."},
      {code:"target_missing",message:"Указанный владелец или элемент отсутствует.",
        operation:{index:0,kind:"updateBlock",target:{kind:"document",id:randomUUID()},id:"no-such-block-v6"}}];
    effects=failures.map((error,index)=>({id:randomUUID(),key:`rejected-${index}`,method:"transaction",
      state:"notSaved",fingerprint:"b".repeat(64),actionID:randomUUID(),error}));
    const rejected=await client.callTool({name:"notebook_execute",arguments:{op:"resume",run_id:id}});
    assert.notEqual(rejected.isError,true,JSON.stringify(rejected));
    assert.deepEqual((rejected.structuredContent as any).effects,effects);
    const parsed=executionOutput.parse(rejected.structuredContent) as any;
    assert.deepEqual(parsed.effects,effects,"Zod must not silently strip operation diagnostics");
    for(const invalid of [{...operation,index:-1},{...operation,index:512},{...operation,id:"x".repeat(121)},
      {...operation,kind:"unknownOperation"},{...operation,values:{source:"must never appear"}}]) {
      const value=structuredClone(parsed);value.effects[0].error.operation=invalid;
      assert.equal(executionOutput.safeParse(value).success,false,"Reject an invalid or source-bearing diagnostic");
    }
    attentionStatus="native_error";
    const refused=await client.callTool({name:"notebook_context",arguments:{method:"attention",args:{contextID:randomUUID(),referenceID:randomUUID()}}});
    assert.equal(refused.isError,true);
    assert.equal((refused.structuredContent as any).status,"error");
    assert.equal((refused.structuredContent as any).code,"capture_failed");
  } finally {
    await client.close();await server.close();await new Promise<void>(resolve=>native.close(()=>resolve()));
    await rm(root,{recursive:true,force:true});
  }
});

test("one MCP deadline includes blocked admission and subsequent image reads, without cancelling accepted work",async()=>{
  const root=await mkdtemp(join(tmpdir(),"notebook-script-deadline-")),path=join(root,"bridge.sock");
  const id=randomUUID(),pollID=randomUUID(),code="return 42",requests:any[]=[],timers:NodeJS.Timeout[]=[];
  let completed=false;
  const receipt=()=>({status:completed?"completed":"queued",run_id:id,fingerprint:"a".repeat(64),api_version:1,
    events:[],next_seq:0,has_more:false,result:completed?42:null,error:null,effects:[],resume_semantics:"attach_only_no_replay"});
  const native=createNativeServer({allowHalfOpen:true},socket=>{
    const chunks:Buffer[]=[];
    socket.on("error",()=>{});
    socket.on("data",data=>chunks.push(Buffer.from(data)));
    socket.on("end",()=>{
      const packet=JSON.parse(Buffer.concat(chunks).subarray(4).toString()),request=packet.request;
      requests.push(request);
      const send=(result:unknown)=>{
        if(socket.destroyed)return;
        const body=Buffer.from(JSON.stringify({version:1,id:packet.id,result})),size=Buffer.alloc(4);size.writeUInt32BE(body.length);
        socket.end(Buffer.concat([size,body]));
      };
      if(request.command==="script"&&request.script.op==="start") {
        // Deliberately synthetic slow owner admission. The native IPC tests
        // separately prove that real accepted writes outlive disconnection.
        timers.push(setTimeout(()=>{completed=true;send(receipt());},4_250));
      } else if(request.command==="script"&&request.script.runID===pollID) {
        // A healthy owner obeys the requested poll duration. It must retain
        // enough of the same four-second budget to send its empty running page.
        timers.push(setTimeout(()=>send({...receipt(),run_id:pollID,status:"running",result:null}),request.script.waitMilliseconds+30));
      } else if(request.command==="scriptContext") {
        timers.push(setTimeout(()=>send({artifact:{kind:"fixture"}}),3_100));
      } else if(request.command==="scriptArtifact") {
        timers.push(setTimeout(()=>send({data:"",mimeType:"image/png",sha256:"a".repeat(64)}),1_200));
      } else send(receipt());
    });
  });
  const server=createServer(path),client=new Client({name:"deadline-contract",version:"1"});
  try {
    await chmod(root,0o700);await new Promise<void>(resolve=>native.listen(path,resolve));await chmod(path,0o600);
    const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);await client.connect(clientTransport);
    const started=performance.now();
    const [run,image,poll]=await Promise.all([
      client.callTool({name:"notebook_execute",arguments:{op:"start",run_id:id,api_version:1,code,wait_ms:4000}}),
      client.callTool({name:"notebook_context",arguments:{method:"observe"}}),
      client.callTool({name:"notebook_execute",arguments:{op:"resume",run_id:pollID,wait_ms:4000}}),
    ]);
    const elapsed=performance.now()-started;
    assert.ok(elapsed<4_150,`whole MCP reply exceeded deadline allowance: ${elapsed}ms`);
    assert.equal(run.isError,true);
    assert.equal((run.structuredContent as any).code,"response_pending");
    assert.equal((run.structuredContent as any).run_id,id);
    assert.equal((run.structuredContent as any).admission,"unknown");
    assert.equal((run.structuredContent as any).after_seq,0);
    assert.equal(image.isError,true);
    assert.equal((image.structuredContent as any).code,"ipc_timeout");
    assert.notEqual(poll.isError,true,JSON.stringify(poll));
    assert.equal((poll.structuredContent as any).status,"running");
    const pollWait=requests.find(request=>request.script?.runID===pollID).script.waitMilliseconds;
    assert.ok(pollWait>3600&&pollWait<=3800,`Native poll received its own deadline: ${pollWait}ms`);
    assert.equal(completed,false,"deadline must not pretend admission completed");
    await new Promise(resolve=>setTimeout(resolve,500));
    assert.equal(completed,true,"closing the socket must not cancel accepted work");
    const resumed=await client.callTool({name:"notebook_execute",arguments:{op:"resume",run_id:id}});
    assert.notEqual(resumed.isError,true,JSON.stringify(resumed));
    assert.equal((resumed.structuredContent as any).result,42);
    assert.equal(requests.filter(request=>request.command==="script"&&request.script.op==="start").length,1);
    assert.equal(requests.filter(request=>request.command==="scriptArtifact").length,1);
  } finally {
    for(const timer of timers)clearTimeout(timer);
    await client.close();await server.close();await new Promise<void>(resolve=>native.close(()=>resolve()));
    await rm(root,{recursive:true,force:true});
  }
});
