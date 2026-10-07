import {panelIdentity,withCohort} from './panel-fixture.js';
import assert from 'node:assert/strict';
import test,{type TestContext} from 'node:test';
import {randomUUID} from 'node:crypto';
import {NotebookSession} from '../panel/session.js';
import type {PanelCheckpoint,PanelMutation,PanelSnapshot} from '../panel/model.js';

type ToolReply=Awaited<ReturnType<NotebookSession['app']['callServerTool']>>;
type Value=Record<string,unknown>;
const address={workspaceID:randomUUID(),socketKey:'0123456789abcdef01234567',target:{kind:'board' as const,id:randomUUID()}};
const origin={tileX:0,tileY:0,localX:0,localY:0},epoch=randomUUID();
const checkpoint=(cursor='1',owner:string=epoch):PanelCheckpoint=>({id:randomUUID(),epoch:owner,readCursor:cursor,changeCursor:cursor});
function snapshot(cursor='1',owner:string=epoch):PanelSnapshot {
  return {...address,cursor,checkpoint:checkpoint(cursor,owner),worldOrigin:origin,size:{width:800,height:600},
    elements:[],cards:[],rawInkPresent:false,unsupportedElements:[],history:{},truncated:false,
    appearance:{status:'ready',requestID:randomUUID(),sourceRevision:cursor,
      camera:{center:origin,scale:1},viewport:{x:800,y:600},layers:[]}};
}
const flush=()=>new Promise<void>(resolve=>setImmediate(resolve));

async function fixture(t:TestContext){
  const prior=Object.getOwnPropertyDescriptor(globalThis,'document');
  const document=new EventTarget() as EventTarget&{hidden:boolean};document.hidden=false;
  Object.defineProperty(globalThis,'document',{configurable:true,value:document});
  const session=new NotebookSession(panelIdentity),errors:string[]=[];
  let disposed=false,lastError='',retry:(()=>Promise<void>)|null=null;
  const calls:{name:string;arguments:Value;signal:AbortSignal|undefined;timeout:number|undefined;
    resolve:(reply:ToolReply)=>void;reject:(error:Error)=>void}[]=[];
  session.app.connect=async()=>{};session.app.updateModelContext=async()=>({});
  session.app.callServerTool=async(input,options)=>new Promise((resolve,reject)=>{
    const abort=()=>reject(new Error('Observation cancelled'));
    if(options?.signal?.aborted){abort();return;}
    options?.signal?.addEventListener('abort',abort,{once:true});
    calls.push({name:input.name,arguments:structuredClone(input.arguments!),signal:options?.signal,timeout:options?.timeout,
      resolve:reply=>{options?.signal?.removeEventListener('abort',abort);resolve(reply);},reject});
  });
  session.needsPresentation=()=>false;
  session.onError=(message,action)=>{assert.equal(disposed,false);lastError=message;retry=action;if(message)errors.push(message);};
  session.onSnapshot=()=>{assert.equal(disposed,false);};
  session.onClose=()=>{disposed=true;};
  const close=()=>session.app.onteardown!({},{} as never);
  t.after(async()=>{await close();if(prior)Object.defineProperty(globalThis,'document',prior);else Reflect.deleteProperty(globalThis,'document');});
  session.snapshot=snapshot();await session.connect();
  const opening=session.refresh(true);calls[0]!.resolve({content:[],structuredContent:snapshot()});await opening;
  const waits=()=>calls.filter(call=>call.name==='notebook_panel_changes');
  const presentations=()=>calls.filter(call=>call.name==='notebook_panel_presentation');
  const changes=(waiting:ReturnType<typeof waits>[number],value:Partial<Value>={})=>{
    waiting.resolve({content:[],structuredContent:{...address,checkpoint:waiting.arguments.checkpoint,changed:false,...value}});
  };
  return {session,calls,waits,presentations,changes,document,errors,close,retry:()=>retry,error:()=>lastError};
}

test('an idle addressed wait rearms without pixels and does not delay a human command',async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,waits,presentations,changes}=await fixture(t);
  assert.equal(waits().length,1);assert.equal(waits()[0]!.timeout,35_000);
  assert.equal(session.busy,false);assert.equal(session.mutationReady,true);
  t.mock.timers.tick(1500);await flush();assert.equal(presentations().length,1,'No 1.5-second scene polling');
  const first=waits()[0]!,advanced={...first.arguments.checkpoint as PanelCheckpoint,readCursor:'5',changeCursor:'4'};
  changes(first,{checkpoint:advanced});await flush();
  assert.equal(waits().length,2);assert.deepEqual(waits()[1]!.arguments.checkpoint,advanced);
  assert.equal(presentations().length,1,'Unrelated committed changes advance observation without a scene');
  const edit:PanelMutation={...address,actionID:randomUUID(),summary:'Edit during observation',sources:[{id:'text'}],
    operations:[{kind:'updateElement',target:address.target,id:'text',values:{source:'new'}}]};
  const saved=session.save(edit),command=calls.find(call=>call.name==='notebook_panel_edit')!;
  assert.deepEqual(command.arguments,withCohort(edit));assert.equal(waits()[1]!.signal?.aborted,false);
  command.resolve({content:[],structuredContent:{status:'saved',actionID:edit.actionID}});await saved;
  assert.equal(presentations().length,2);
  presentations()[1]!.resolve({content:[],structuredContent:snapshot('6')});await flush();
  assert.equal(session.mutationReady,true);assert.equal(waits()[1]!.signal?.aborted,true);
  assert.equal(waits().length,3);
});

test('dirty changes survive contact and rejected preparation, then recover with one backoff',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});
  const {session,waits,presentations,changes}=await fixture(t);
  session.suspended=true;changes(waits()[0]!,{changed:true});await flush();
  assert.equal(presentations().length,1);assert.equal(waits().length,1);
  let ready=false;session.onPrepareSnapshot=async()=>ready;
  session.suspended=false;await flush();assert.equal(presentations().length,2);
  presentations()[1]!.resolve({content:[],structuredContent:snapshot('2')});await flush();
  assert.equal(session.snapshot!.cursor,'1');assert.equal(waits().length,1,'An invalidated checkpoint is never rearmed');
  t.mock.timers.tick(249);await flush();assert.equal(presentations().length,2);
  t.mock.timers.tick(1);await flush();assert.equal(presentations().length,3);
  assert.equal(presentations()[2]!.arguments.knownCursor,undefined);
  ready=true;presentations()[2]!.resolve({content:[],structuredContent:snapshot('3')});await flush();
  assert.equal(session.snapshot!.cursor,'3');assert.equal(waits().length,2);
  t.mock.timers.tick(4000);await flush();assert.equal(presentations().length,3,'Acceptance ends recovery timers');
});

test('hidden, navigation and teardown revoke only their wait and discard late results',async t=>{
  const {session,waits,presentations,changes,document,close}=await fixture(t);
  const first=waits()[0]!;document.hidden=true;document.dispatchEvent(new Event('visibilitychange'));
  assert.equal(first.signal?.aborted,true);
  changes(first,{changed:true});await flush();assert.equal(presentations().length,1);
  document.hidden=false;document.dispatchEvent(new Event('visibilitychange'));
  assert.equal(waits().length,2);
  const destination={kind:'page' as const,id:randomUUID()},opening=session.openSurface(destination);
  assert.equal(waits()[1]!.signal?.aborted,true);
  presentations()[1]!.resolve({content:[],structuredContent:{...snapshot('2'),target:destination}});
  assert.equal(await opening,true);assert.equal(waits().length,3);
  assert.deepEqual(waits()[2]!.arguments.target,destination);
  await close();assert.equal(waits()[2]!.signal?.aborted,true);await flush();
  document.dispatchEvent(new Event('visibilitychange'));assert.equal(waits().length,3);
});

test('wait failures retry delivery without serializing commands or preparing idle pixels',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});
  const {session,waits,presentations,changes,errors}=await fixture(t);
  waits()[0]!.reject(new Error('Temporary connection loss'));await flush();
  assert.equal(session.mutationReady,true);assert.equal(errors.length,1);
  t.mock.timers.tick(250);await flush();assert.equal(waits().length,2);assert.equal(presentations().length,1);
  changes(waits()[1]!);await flush();assert.equal(waits().length,3);
  t.mock.timers.tick(4000);await flush();assert.equal(presentations().length,1);
});

test('workspace selection revokes the old subscription before awaiting the new owner',async t=>{
  const {session,calls,waits,presentations,changes}=await fixture(t),old=waits()[0]!;
  const nextWorkspace=randomUUID(),selection=session.workspace({action:'select',id:nextWorkspace});
  assert.equal(old.signal?.aborted,true);
  changes(old,{changed:true});await flush();assert.equal(presentations().length,1);
  const selecting=calls.find(call=>call.name==='notebook_panel_workspace')!;
  const selected={...snapshot('2'),workspaceID:nextWorkspace,socketKey:'fedcba9876543210fedcba98'};
  selecting.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:2,state:'ready',
    workspaceID:nextWorkspace,socketKey:selected.socketKey},workspaces:[],snapshot:selected}});
  await selection;assert.equal(presentations().length,2);
  presentations()[1]!.resolve({content:[],structuredContent:selected});await flush();
  assert.equal(waits().length,2);assert.equal(waits()[1]!.arguments.workspaceID,nextWorkspace);
  assert.equal(waits()[1]!.arguments.socketKey,selected.socketKey);
});

test('an invalidation during an unchanged presentation retains dirty demand for fresh pixels',async t=>{
  const {session,waits,presentations,changes}=await fixture(t),initial=session.snapshot!;
  const reading=session.refresh();changes(waits()[0]!,{changed:true});await flush();
  presentations()[1]!.resolve({content:[],structuredContent:{...address,cursor:initial.cursor,unchanged:true}});
  await reading;await flush();assert.equal(presentations().length,3);
  assert.equal(presentations()[2]!.arguments.knownRequestID,undefined);
  presentations()[2]!.resolve({content:[],structuredContent:snapshot('2')});await flush();
  assert.equal(session.snapshot!.cursor,'2');assert.equal(waits().length,2);
});

test('dirty delivery preserves an uncertain action until its exact retry and accepted scene',async t=>{
  const {session,calls,waits,presentations,changes,retry}=await fixture(t);
  const edit:PanelMutation={...address,actionID:randomUUID(),summary:'Uncertain addressed edit',sources:[{id:'text'}],
    operations:[{kind:'updateElement',target:address.target,id:'text',values:{source:'new'}}]};
  const saved=session.save(edit),write=calls.find(call=>call.name==='notebook_panel_edit')!;
  write.resolve({content:[],isError:true,structuredContent:{status:'error',code:'ipc_timeout',message:'Unknown accepted result'}});
  await flush();const retryWrite=retry();assert.ok(retryWrite);
  changes(waits()[0]!,{changed:true});await flush();
  assert.equal(retry(),retryWrite);assert.equal(session.hasPending,true);assert.equal(presentations().length,1);
  const repaired=retryWrite(),recovery=calls.find(call=>call.name==='notebook_panel_workspace')!;
  recovery.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:2,state:'ready',
    workspaceID:address.workspaceID,socketKey:address.socketKey},workspaces:[],snapshot:snapshot()}});
  await repaired;
  const writes=calls.filter(call=>call.name==='notebook_panel_edit');assert.equal(writes.length,2);
  assert.deepEqual(writes[1]!.arguments,write.arguments);assert.equal(writes[1]!.arguments.actionID,edit.actionID);
  writes[1]!.resolve({content:[],structuredContent:{status:'saved',actionID:edit.actionID}});await saved;
  presentations()[1]!.resolve({content:[],structuredContent:snapshot('2')});await flush();
  assert.equal(session.hasPending,false);assert.equal(session.mutationReady,true);assert.equal(waits().length,2);
});

test('retiring a cohort preserves a dispatched write outcome and the terminal reopening state',async t=>{
  for(const outcome of ['saved','ipc_timeout'] as const)await t.test(outcome,async t=>{
    t.mock.timers.enable({apis:['setTimeout']});
    const {session,calls,waits,presentations,retry,error,close}=await fixture(t),accepted=session.snapshot;
    let cancellations=0,preparations=0,finishPreparation:((ready:boolean)=>void)|undefined;
    session.onPrepareSnapshot=async()=>{preparations++;return new Promise<boolean>(resolve=>{finishPreparation=resolve;});};
    session.onCancelSnapshotPreparation=async()=>{cancellations++;finishPreparation?.(false);};
    const reading=session.refresh(true),lateRead=presentations()[1]!;
    if(outcome==='saved'){
      lateRead.resolve({content:[],structuredContent:snapshot('2')});await flush();
      assert.equal(preparations,1,'An ordinary refresh holds an unaccepted candidate');
    }
    const edit:PanelMutation={...address,actionID:randomUUID(),summary:'Write crossing cohort retirement',sources:[{id:'text'}],
      operations:[{kind:'updateElement',target:address.target,id:'text',values:{source:'new'}}]};
    let settlement='pending';
    const saved=session.save(edit),completed=saved.then(()=>{settlement='saved';},()=>{settlement='rejected';});
    const write=calls.find(call=>call.name==='notebook_panel_edit')!;
    assert.deepEqual(write.arguments,withCohort(edit));
    waits()[0]!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'panel_update_required',
      message:'Откройте новую панель через @Notebook в этом чате.'}});
    await flush();assert.equal(session.hasAppearance,false);assert.equal(session.hasPending,true);
    assert.equal(cancellations,1,'Retirement also revokes preparation without navigation');
    assert.equal(retry(),null);assert.match(error(),/@Notebook/);assert.equal(settlement,'pending');
    if(outcome==='ipc_timeout')lateRead.resolve({content:[],structuredContent:snapshot('2')});
    await reading;assert.equal(preparations,outcome==='saved'?1:0);
    assert.equal(session.snapshot,accepted,'A retired read cannot replace the accepted scene');
    write.resolve(outcome==='saved'?{content:[],structuredContent:{status:'saved',actionID:edit.actionID}}:
      {content:[],isError:true,structuredContent:{status:'error',code:'ipc_timeout',message:'Unknown accepted result'}});
    await flush();assert.equal(settlement,outcome==='saved'?'saved':'pending');
    assert.equal(session.hasPending,outcome!=='saved');assert.equal(session.mutationReady,false);
    assert.equal(retry(),null);assert.match(error(),/@Notebook/);
    if(outcome==='ipc_timeout')assert.match(error(),/Unknown accepted result/);
    await assert.rejects(session.save({...edit,actionID:randomUUID()}),/@Notebook/);
    t.mock.timers.tick(40_000);await flush();
    assert.equal(calls.length,4,'Retirement performs no refresh, recovery, replay or new write');
    assert.equal(calls.filter(call=>call.name==='notebook_panel_edit').length,1);
    assert.equal(retry(),null);assert.match(error(),/@Notebook/);
    await close();await completed;
  });
  for(const code of ['panel_update_required','runtime_update_required'] as const)
  for(const refusal of ['first edit','workspace','repeated edit'] as const)await t.test(`${code} at ${refusal} retires the view and preserves the original outcome`,async t=>{
    const {session,calls,retry,error,close}=await fixture(t);
    const edit:PanelMutation={...address,actionID:randomUUID(),summary:'Uncertain write before cohort recovery',sources:[{id:'text'}],
      operations:[{kind:'updateElement',target:address.target,id:'text',values:{source:'new'}}]};
    let settlement='pending';
    const completed=session.save(edit).then(()=>{settlement='saved';},()=>{settlement='rejected';});
    const write=calls.find(call=>call.name==='notebook_panel_edit')!;
    const message=code==='panel_update_required'?'Откройте новую панель через @Notebook в этом чате.':
      'Installed runtime build 260 differs from required 259.';
    const denied={content:[],isError:true,structuredContent:{status:'error',code,message}};
    if(refusal==='first edit')write.resolve(denied);
    else{
      write.resolve({content:[],isError:true,structuredContent:{status:'error',code:'ipc_timeout',message:'Unknown accepted result'}});
      await flush();const retryWrite=retry();assert.ok(retryWrite);
      const recovery=retryWrite(),request=calls.find(call=>call.name==='notebook_panel_workspace')!;
      if(refusal==='workspace')request.resolve(denied);
      else{
        request.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:2,state:'ready',
          workspaceID:address.workspaceID,socketKey:address.socketKey},workspaces:[],snapshot:snapshot()}});
        await recovery;
        const repeated=calls.filter(call=>call.name==='notebook_panel_edit')[1]!;
        assert.deepEqual(repeated.arguments,write.arguments,'An explicit retry preserves the unknown action ID and sources');
        repeated.resolve(denied);
      }
      await flush();
      await recovery;
      await retryWrite();
    }
    await flush();
    assert.equal(session.hasPending,refusal!=='first edit');assert.equal(settlement,refusal==='first edit'?'rejected':'pending');
    assert.equal(session.hasAppearance,false);assert.equal(retry(),null);assert.equal(error(),message,'The original version-refusal diagnostic is retained');
    await assert.rejects(session.save({...edit,actionID:randomUUID()}),{message});
    assert.equal(calls.length,refusal==='first edit'?3:refusal==='workspace'?4:5,'A retired cohort cannot recover or replay');
    assert.equal(calls.filter(call=>call.name==='notebook_panel_edit').length,refusal==='repeated edit'?2:1);
    assert.deepEqual(write.arguments,withCohort(edit));
    await close();await completed;
  });
});

test('an older ready cohort retains invalidation and retries without rolling the scene back',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});
  const {session,waits,presentations,changes}=await fixture(t);
  changes(waits()[0]!,{changed:true});await flush();
  presentations()[1]!.resolve({content:[],structuredContent:snapshot('0')});await flush();
  assert.equal(session.snapshot!.cursor,'1');assert.equal(waits().length,1);
  t.mock.timers.tick(250);await flush();assert.equal(presentations().length,3);
  presentations()[2]!.resolve({content:[],structuredContent:snapshot('2')});await flush();
  assert.equal(session.snapshot!.cursor,'2');assert.equal(waits().length,2);
});

test('a changed epoch requires reset, and reset is accepted only through fresh pixels',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});
  const {session,waits,presentations,changes,errors}=await fixture(t),replacement=checkpoint('0',randomUUID());
  changes(waits()[0]!,{checkpoint:replacement});await flush();
  assert.equal(errors.length,1);assert.equal(session.snapshot!.checkpoint!.epoch,epoch);
  t.mock.timers.tick(250);await flush();
  changes(waits()[1]!,{checkpoint:replacement,changed:true,reset:true});await flush();
  assert.equal(presentations().length,2);assert.equal(waits().length,2);
  presentations()[1]!.resolve({content:[],structuredContent:snapshot('0',replacement.epoch)});await flush();
  assert.equal(session.snapshot!.checkpoint!.epoch,replacement.epoch);assert.equal(waits().length,3);
});

test('foreign observation and ready pixels without checkpoint cannot replace the accepted scene',async t=>{
  t.mock.timers.enable({apis:['setTimeout']});
  const {session,waits,presentations,changes,errors}=await fixture(t);
  changes(waits()[0]!,{workspaceID:randomUUID(),changed:true});await flush();
  assert.equal(errors.length,1);assert.equal(presentations().length,1);
  const reading=session.refresh(true),incomplete=snapshot('2');delete incomplete.checkpoint;
  let preparations=0;session.onPrepareSnapshot=async()=>{preparations++;return true;};
  presentations()[1]!.resolve({content:[],structuredContent:incomplete});await reading;
  assert.equal(preparations,0);assert.equal(session.snapshot!.cursor,'1');assert.equal(errors.length,2);
});
