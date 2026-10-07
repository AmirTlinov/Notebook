import assert from 'node:assert/strict';
import test, {type TestContext} from 'node:test';
import {randomUUID} from 'node:crypto';
import {chmod, mkdtemp, rm} from 'node:fs/promises';
import {createServer, type Socket} from 'node:net';
import {join} from 'node:path';
import {Client, InMemoryTransport} from '@modelcontextprotocol/client';
import {McpServer} from '@modelcontextprotocol/server';
import {RESOURCE_MIME_TYPE} from '@modelcontextprotocol/ext-apps/server';
import {panelResourceURI, registerNotebookPanel} from '../src/panel-tools.js';
import {NotebookSession} from '../panel/session.js';
import {Surface} from '../panel/surface.js';
import type {PanelMutation, PanelSnapshot, PanelView} from '../panel/model.js';

type Value = Record<string, unknown>;
type Reply = {result: Value} | {error: Value};
const html = '<!doctype html><html><body>Notebook panel fixture</body></html>';
const socketKey = '0123456789abcdef01234567';
const workspaceID = randomUUID();
const target = {kind: 'board', id: randomUUID()};
const address = {workspaceID, target, socketKey};
const origin = {tileX: 7, tileY: -3, localX: 40, localY: 60};

function materialFixture(t:TestContext) {
  const display={devicePixelRatio:1},dimensions={width:800,height:600};
  class NodePort {
    children:NodePort[]=[];attributes=new Map<string,string>();style={};clientWidth=800;clientHeight=600;
    ownerDocument={defaultView:display};
    setAttribute(key:string,value:string){this.attributes.set(key,value);}
    removeAttribute(key:string){this.attributes.delete(key);}
    append(...nodes:NodePort[]){this.children.push(...nodes);}
    insertBefore(node:NodePort,before:NodePort|null){this.children.splice(before?this.children.indexOf(before):this.children.length,0,node);}
    replaceChildren(...nodes:NodePort[]){this.children=nodes;}
    get firstChild():NodePort|null{return this.children[0]??null;}
  }
  const priorDocument=Object.getOwnPropertyDescriptor(globalThis,'document'),priorImage=Object.getOwnPropertyDescriptor(globalThis,'Image');
  Object.defineProperty(globalThis,'document',{configurable:true,value:{activeElement:null,
    createElementNS:()=>new NodePort(),createDocumentFragment:()=>new NodePort()}});
  Object.defineProperty(globalThis,'Image',{configurable:true,value:class {
    naturalWidth=dimensions.width;naturalHeight=dimensions.height;src='';async decode(){}
  }});
  const surface=new Surface(new NodePort() as unknown as SVGSVGElement,new NodePort() as unknown as SVGGElement,new NodePort() as unknown as SVGGElement);
  surface.setCamera({x:0,y:0,scale:1});
  t.after(()=>{surface.dispose();for(const [key,prior] of [['document',priorDocument],['Image',priorImage]] as const){
    if(prior)Object.defineProperty(globalThis,key,prior);else Reflect.deleteProperty(globalThis,key);
  }});
  const anchor={tileX:0,tileY:0,localX:0,localY:0};
  const snapshot=(density:number,width=800,height=600,revision='same-source'):PanelSnapshot=>({
    ...address,target:{kind:'board',id:target.id},cursor:'10',worldOrigin:anchor,size:{width:1600,height:1200},elements:[],cards:[],rawInkPresent:false,
    unsupportedElements:[],history:{},truncated:false,appearance:{status:'ready',requestID:randomUUID(),sourceRevision:revision,
      camera:{center:{...anchor,localX:width/2,localY:height/2},scale:800/width},viewport:{x:800,y:600},
      coverage:{anchor,region:{x:0,y:0,width,height},level:0,pixelDensity:density},layers:[{
        id:'native-material',assetID:randomUUID(),worldOrigin:anchor,frame:{x:0,y:0,width,height},order:0,
        pixelWidth:width*density,pixelHeight:height*density,pngBase64:'iVBORw0KGgo=',sha256:'a'.repeat(64)}]}});
  const prepare=(value:PanelSnapshot,pixelScale=1)=>{
    dimensions.width=value.appearance!.layers[0]!.pixelWidth;dimensions.height=value.appearance!.layers[0]!.pixelHeight;
    const view:PanelView={viewport:{x:800,y:600},pixelScale,camera:value.appearance!.camera};
    return surface.prepare(value,view);
  };
  return {surface,display,snapshot,prepare};
}

test('same-source late coarse material cannot replace sharper pixels at the current zoom',async t=>{
  const {surface,snapshot,prepare}=materialFixture(t),sharp=snapshot(1),coarse=snapshot(.5,1600,1200);
  assert.equal(await prepare(sharp),true);surface.render(sharp);
  const held=surface.assetIDs;
  assert.equal(await prepare(coarse),false,'Equal visible coverage must not reduce current pixel adequacy');
  assert.deepEqual(surface.assetIDs,held);
});

test('zoom-out admits lower excess density using the current display scale',async t=>{
  const {surface,display,snapshot,prepare}=materialFixture(t),sharp=snapshot(1,1600,1200),coarse=snapshot(.5,1600,1200);
  display.devicePixelRatio=2;assert.equal(await prepare(sharp,2),true);surface.render(sharp);
  display.devicePixelRatio=1;surface.setCamera({x:0,y:0,scale:.5});
  assert.equal(await prepare(coarse,2),true,'Stale request DPR must not outweigh the current adequate density');
  surface.render(coarse);assert.deepEqual(surface.assetIDs,[coarse.appearance!.layers[0]!.assetID]);
});

test('an inadequate prior admits the current native pixel budget reply and ends demand',async t=>{
  const {surface,snapshot,prepare}=materialFixture(t),prior=snapshot(1.5),bounded=snapshot(1);
  prior.appearance!.camera.scale=1.5;surface.setCamera({x:0,y:0,scale:2});
  assert.equal(await prepare(prior),true);surface.render(prior);
  bounded.appearance!.camera={center:{tileX:0,tileY:0,localX:200,localY:150},scale:2};
  const view={viewport:{x:800,y:600},pixelScale:1,camera:bounded.appearance!.camera};
  const bounds={anchor:bounded.worldOrigin!,region:{x:0,y:0,width:400,height:300}};
  assert.equal(surface.covers(bounds,view),false);
  assert.equal(await prepare(bounded),true);surface.render(bounded);
  assert.equal(surface.covers(bounds,view),true,'The same bounded projection must not rerender every polling tick');
});

test('coarser material still admits fresh source identity and visible coverage gains',async t=>{
  for(const change of ['revision','workspace','endpoint','coverage'] as const)await t.test(change,async t=>{
    const {surface,snapshot,prepare}=materialFixture(t),sharp=snapshot(1),coarse=snapshot(.5,1600,1200);
    assert.equal(await prepare(sharp),true);surface.render(sharp);
    if(change==='revision')coarse.appearance!.sourceRevision='new-source';
    if(change==='workspace')coarse.workspaceID=randomUUID();
    if(change==='endpoint')coarse.socketKey='abcdef0123456789abcdef0123456789';
    if(change==='coverage')surface.setCamera({x:400,y:0,scale:1});
    assert.equal(await prepare(coarse),true,change);surface.render(coarse);
    assert.deepEqual(surface.assetIDs,[coarse.appearance!.layers[0]!.assetID]);
  });
});

test('session coalesces viewport demand against accepted pixels without delaying required reads', async t => {
  for (const scenario of ['covered', 'needed', 'forced', 'fit'] as const) await t.test(scenario, async t => {
    t.mock.timers.enable({apis: ['setTimeout']});
    const session = new NotebookSession();
    let density = 0, wanted = 1;
    const calls: {arguments: Value; resolve: (value: Awaited<ReturnType<typeof session.app.callServerTool>>) => void}[] = [];
    const contexts: Value[] = [];
    session.app.callServerTool = async input => new Promise(resolve => calls.push({arguments: input.arguments!, resolve}));
    session.app.updateModelContext = async input => {contexts.push(JSON.parse((input.content![0] as {text: string}).text)); return {};};
    session.view = () => ({viewport: {x: 800, y: 600}, pixelScale: 1, camera: {center: origin, scale: wanted}});
    session.bounds = () => ({anchor: origin, region: {x: 0, y: 0, width: 800 / wanted, height: 600 / wanted}});
    session.needsPresentation = () => density < wanted;
    session.onSnapshot = value => {density = value.appearance!.coverage!.pixelDensity;};
    const snapshot = (scale: number, pixels: number, cursor: string): PanelSnapshot => ({
      ...address, target: {...target, kind: 'board'}, cursor, worldOrigin: origin, size: {width: 800, height: 600},
      elements: [], cards: [], rawInkPresent: false, unsupportedElements: [], history: {}, truncated: false,
      appearance: {status: 'ready', requestID: randomUUID(), sourceRevision: 'same-source',
        camera: {center: origin, scale}, viewport: {x: 800, y: 600}, layers: [],
        coverage: {anchor: origin, region: {x: 0, y: 0, width: 800, height: 600}, level: 0, pixelDensity: pixels}},
      ...(scenario === 'fit' ? {fitBounds: {anchor: origin, region: {x: 0, y: 0, width: 1200, height: 900}}} : {}),
    });
    session.snapshot = snapshot(1, 1, '1');
    const initial = session.refresh(true);
    calls[0]!.resolve({content: [], structuredContent: snapshot(1, 1, '1')});
    await initial;
    wanted = 1.28; session.viewportChanged(); t.mock.timers.tick(80);
    assert.equal(calls.length, 2);
    wanted = 1.906; session.viewportChanged(); t.mock.timers.tick(80);
    assert.equal(calls.length, 2, 'The active native read stays serial while the latest camera coalesces');
    if (scenario === 'forced') await session.refresh(true);
    const fit = scenario === 'fit' ? session.requestFit() : undefined;
    calls[1]!.resolve({content: [], structuredContent: snapshot(1.28, scenario === 'needed' ? 1.28 : 2.463, '2')});
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(density, scenario === 'needed' ? 1.28 : 2.463, 'A useful intermediate cohort is accepted');
    assert.equal(calls.length, scenario === 'covered' ? 2 : 3,
      'Covered camera demand is dropped; unmet demand or explicit reads run without another 80ms');
    if (scenario !== 'covered') {
      assert.equal(calls[2]!.arguments.includeFitBounds, scenario === 'fit' ? true : undefined,
        'An explicit fit reader gets the released read slot before viewport-only work');
      assert.equal(calls[2]!.arguments.knownRequestID, undefined, 'Content invalidation is not downgraded to an idle shortcut');
      calls[2]!.resolve({content: [], structuredContent: snapshot(wanted, 2.463, '3')});
      await new Promise<void>(resolve => setImmediate(resolve));
      if (fit) assert.deepEqual(await fit, snapshot(wanted, 2.463, '3').fitBounds);
    }
    t.mock.timers.tick(40);
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal((contexts.at(-1)!.notebookPanel as Value).visibleBounds &&
      ((contexts.at(-1)!.notebookPanel as Value).visibleBounds as {region: {width: number}}).region.width, 800 / wanted,
      'Dropping a redundant camera read preserves the latest context bounds');
    t.mock.timers.tick(80);
    assert.equal(calls.length, scenario === 'covered' ? 2 : 3);
  });
});

function sessionSnapshot(cursor = '1'): PanelSnapshot {
  return {...address, target: {...target, kind: 'board'}, cursor, worldOrigin: origin,
    size: {width: 800, height: 600}, elements: [], cards: [], rawInkPresent: false,
    unsupportedElements: [], history: {}, truncated: false,
    appearance: {status: 'ready', requestID: randomUUID(), sourceRevision: cursor,
      camera: {center: origin, scale: 1}, viewport: {x: 800, y: 600}, layers: []}};
}

async function controlledSession() {
  const session = new NotebookSession(), events: string[] = [];
  const calls: {name: string; arguments: Value;
    resolve: (value: Awaited<ReturnType<typeof session.app.callServerTool>>) => void}[] = [];
  let disposed = false, retry: (() => Promise<void>) | null = null;
  const observe = (event: string) => {assert.equal(disposed, false, `Callback after disposal: ${event}`); events.push(event);};
  session.app.connect = async () => {};
  session.app.callServerTool = async input => new Promise(resolve => calls.push({name: input.name, arguments: input.arguments!, resolve}));
  session.app.updateModelContext = async () => ({});
  session.needsPresentation = () => {observe('coverage'); return true;};
  session.onPrepareSnapshot = async () => {observe('prepare'); return true;};
  session.onSnapshot = () => observe('snapshot');
  session.onStatus = text => observe(text);
  session.onError = (_message, action) => {observe('error'); retry = action;};
  session.onClose = () => {observe('close'); disposed = true;};
  session.snapshot = sessionSnapshot();
  await session.connect();
  const initial = session.refresh(true);
  calls[0]!.resolve({content: [], structuredContent: sessionSnapshot()});
  await initial;
  // The registered handler does not consume request context in these scenarios.
  const close = () => session.app.onteardown!({}, {} as never);
  const mutation: PanelMutation = {...address, target: session.snapshot.target, actionID: randomUUID(), summary: 'Edit text',
    operations: [{kind: 'updateElement', target: session.snapshot.target, id: 'text', values: {source: 'Edited'}}],
    sources: [{id: 'text'}]};
  return {session, calls, events, close, mutation, retry: () => retry};
}

test('a rejected coarse reply settles idle status while retaining write recovery state',async t=>{
  for(const state of ['idle','synchronizing','failedWrite'] as const)await t.test(state,async t=>{
    t.mock.timers.enable({apis:['setTimeout','setInterval']});
    const material=materialFixture(t),{session,calls,close}=await controlledSession();
    const sharp=material.snapshot(1),coarse=material.snapshot(.5,1600,1200);
    assert.equal(await material.prepare(sharp),true);material.surface.render(sharp);session.snapshot=sharp;
    const view={viewport:{x:800,y:600},pixelScale:1,camera:sharp.appearance!.camera};
    const bounds={anchor:sharp.worldOrigin!,region:{x:0,y:0,width:800,height:600}};
    session.needsPresentation=()=>!material.surface.covers(bounds,view);
    session.onPrepareSnapshot=value=>material.prepare(value);
    let accepted=0;const statuses:string[]=[],errors:string[]=[];
    session.onSnapshot=()=>{accepted++;};session.onStatus=text=>statuses.push(text);session.onError=message=>errors.push(message);
    if(state!=='idle')Object.defineProperty(session,state,{value:true,writable:true});
    const held=material.surface.assetIDs,read=session.refresh(true);
    assert.equal(statuses.at(-1),'Подготовка поверхности…');
    calls[1]!.resolve({content:[],structuredContent:coarse});await read;
    assert.equal(accepted,0);assert.equal(session.snapshot,sharp);assert.deepEqual(material.surface.assetIDs,held);
    if(state==='idle'){
      assert.equal(statuses.at(-1),'Подключено');assert.equal(errors.at(-1),'');assert.equal(session.mutationReady,true);
    }else{
      assert.equal(statuses.at(-1),'Подготовка поверхности…');assert.equal(errors.length,0);
      assert.equal((session as unknown as Record<string,unknown>)[state],true);
      if(state==='synchronizing')assert.equal(session.mutationReady,false,'Retained pixels do not confirm accepted-write history');
    }
    assert.equal(calls.length,2,'No idle timer was needed to settle the retained frame');
    await close();
  });
});

test('session teardown releases readers and ignores late read and write completions', async t => {
  for (const outcome of ['read', 'saved', 'conflict', 'uncertain'] as const) await t.test(outcome, async t => {
    t.mock.timers.enable({apis: ['setTimeout', 'setInterval']});
    const {session, calls, events, close, mutation} = await controlledSession();
    const read = outcome === 'read' ? session.refresh(true) : undefined;
    const fitResults: unknown[] = [];
    const fits = read ? [session.requestFit(), session.requestFit()].map(async value => fitResults.push(await value)) : [];
    const write = outcome !== 'read' ? assert.rejects(session.save(mutation), /Панель закрыта/) : undefined;
    session.viewportChanged();
    assert.equal(calls.length, 2);
    await close();
    await write;
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(fitResults.length, fits.length, 'Readers leave immediately, without waiting for the native read');
    assert.ok(fitResults.every(value => value === undefined));
    const afterClose = events.slice();
    assert.equal(session.hasAppearance, false);
    assert.equal(session.hasPending, false);
    assert.equal(session.busy, false);
    const result = outcome === 'read' ? sessionSnapshot('2') : outcome === 'saved' ? {status: 'saved'}
      : {status: 'error', code: outcome === 'conflict' ? 'revision_conflict' : 'ipc_timeout', message: outcome};
    calls[1]!.resolve({content: [], structuredContent: result,
      ...(outcome === 'conflict' || outcome === 'uncertain' ? {isError: true} : {})});
    await read;
    await Promise.all(fits);
    await new Promise<void>(resolve => setImmediate(resolve));
    // Host notifications and viewport events may already be queued at teardown.
    session.app.ontoolresult!({content: [], structuredContent: sessionSnapshot('3')});
    session.viewportChanged();session.context(null);await close();
    t.mock.timers.tick(3000);
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.deepEqual(events, afterClose);
    assert.equal(calls.length, 2, 'No late refresh, retry or polling after disposal');
    assert.equal(session.snapshot?.cursor, '1');
    assert.equal(session.mutationReady, false);
  });
});

test('navigation publishes ready controls immediately after the new surface is accepted',async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,close}=await controlledSession();
  session.needsPresentation=()=>false;
  const availability:boolean[]=[];
  session.onStateChange=()=>availability.push(session.mutationReady);
  const destination={kind:'board' as const,id:randomUUID()};
  const opening=session.openSurface(destination);
  assert.equal(availability.at(-1),false);
  calls[1]!.resolve({content:[],structuredContent:{...sessionSnapshot('2'),target:destination}});
  assert.equal(await opening,true);
  assert.equal(availability.at(-1),true,'Controls must update without waiting for the next polling tick');
  assert.equal(calls.length,2);
  const next=session.openSurface(sessionSnapshot().target);
  assert.equal(calls.length,3,'An immediately repeated navigation can start');
  calls[2]!.resolve({content:[],structuredContent:sessionSnapshot('3')});
  assert.equal(await next,true);
  await close();
  const count=availability.length;
  session.busy=true;session.busy=false;
  assert.equal(availability.length,count,'Disposed controls receive no activity notifications');
});

test('a confirmed pen contact replaces an in-flight old scene before the next polling tick', async t => {
  t.mock.timers.enable({apis: ['setTimeout', 'setInterval']});
  const {session, calls, close} = await controlledSession();
  session.needsPresentation = () => false;
  session.viewportChanged();
  const oldRead = session.refresh();
  const contact: PanelMutation = {...address, target: session.snapshot!.target,
    actionID: randomUUID(), summary: 'Measured pen contact', sources: [],
    operations: [{kind: 'appendInkStroke', target: session.snapshot!.target, id: randomUUID(),
      values: {worldOrigin: origin, points: [{x: 0, y: 0, width: 2.2, opacity: 0.7,
        timeOffset: 0.123456789, force: 0.45, azimuth: 1.2, altitude: 0.8}]}}]};
  const saved = session.save(contact);
  assert.equal(calls[2]!.name, 'notebook_panel_edit');
  assert.equal(calls[2]!.arguments.actionID, contact.actionID);
  assert.deepEqual(calls[2]!.arguments.operations, contact.operations);
  assert.deepEqual(calls[2]!.arguments.sources, []);
  calls[2]!.resolve({content: [], structuredContent: {status: 'saved', actionID: contact.actionID}});
  await saved;
  assert.equal(session.mutationReady, false, 'The sealed contact still awaits its accepted scene');
  assert.equal(calls.length, 3, 'The old read retains the serial reader slot');
  calls[1]!.resolve({content: [], structuredContent: sessionSnapshot('1')});
  await oldRead;
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(calls.length, 4, 'Content refresh runs without advancing the 1500ms timer');
  assert.equal(calls[3]!.name, 'notebook_panel_presentation');
  assert.equal(calls[3]!.arguments.knownCursor, undefined, 'The old cohort cannot authorize an unchanged response');
  calls[3]!.resolve({content: [], structuredContent: {...sessionSnapshot('2'), rawInkPresent: true,
    history: {undoActionID: contact.actionID}}});
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(session.snapshot!.cursor, '2');
  assert.equal(session.snapshot!.history.undoActionID, contact.actionID);
  assert.equal(session.mutationReady, true, 'A second measured contact is immediately admissible');
  const next = {...contact, actionID: randomUUID(), operations: [{...contact.operations[0]!, id: randomUUID()}]};
  const second = session.save(next);
  assert.equal(calls[4]!.arguments.actionID, next.actionID);
  assert.notEqual(calls[4]!.arguments.actionID, contact.actionID);
  calls[4]!.resolve({content: [], structuredContent: {status: 'saved', actionID: next.actionID}});
  await second;
  calls[5]!.resolve({content: [], structuredContent: sessionSnapshot('3')});
  await new Promise<void>(resolve => setImmediate(resolve));
  await close();
});

test('an unfinished contact owns mutation admission until completion or cancellation',async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,close,mutation}=await controlledSession();
  session.snapshot!.history.undoActionID=randomUUID();
  session.suspended=true;
  assert.equal(session.mutationReady,false);
  await assert.rejects(session.save(mutation),/Дождитесь/);
  await assert.rejects(session.undo(),/Дождитесь/);
  assert.equal(calls.length,1,'No competing action reaches the runtime');
  assert.equal(session.hasPending,false);
  session.suspended=false;
  assert.equal(session.mutationReady,true);
  const saved=session.save(mutation);
  assert.equal(calls[1]!.name,'notebook_panel_edit');
  calls[1]!.resolve({content:[],structuredContent:{status:'saved'}});await saved;
  calls[2]!.resolve({content:[],structuredContent:sessionSnapshot('2')});
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(session.mutationReady,true);
  await close();
});

for(const code of ['ipc_timeout','operation_failed','runtime_starting','runtime_startup_failed'])test(`error Retry repairs ${code} before repeating the same text action`, async t => {
  t.mock.timers.enable({apis: ['setTimeout', 'setInterval']});
  const {session, calls, close, mutation, retry} = await controlledSession();
  const saved = session.save(mutation);
  calls[1]!.resolve({content: [], isError: true,
    structuredContent: {status: 'error', code, message: 'The text write needs recovery'}});
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(session.hasPending, true);
  assert.equal(session.mutationReady, false);
  assert.equal(session.busy, false);
  const retryWrite = retry();assert.ok(retryWrite);
  const retried = retryWrite();
  assert.equal(calls[2]!.name,'notebook_panel_workspace');
  assert.deepEqual(calls[2]!.arguments,{action:'retry',id:mutation.workspaceID});
  calls[2]!.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:1,state:'ready',workspaceID,socketKey},workspaces:[],snapshot:sessionSnapshot()}});
  await retried;
  assert.equal(calls[3]!.name, calls[1]!.name);
  assert.deepEqual(calls[3]!.arguments, calls[1]!.arguments);
  assert.equal(calls[3]!.arguments.actionID, mutation.actionID);
  calls[3]!.resolve({content: [], structuredContent: {status: 'saved', actionID: mutation.actionID}});
  await saved;
  assert.equal(session.hasPending, false);
  assert.equal(session.mutationReady, false, 'A confirmed write still waits for its presented content');
  assert.equal(calls[4]!.name, 'notebook_panel_presentation');
  calls[4]!.resolve({content: [], structuredContent: sessionSnapshot('2')});
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(session.mutationReady, true);
  assert.equal(session.snapshot?.cursor, '2');
  await close();
});

test('workspace recovery preserves an uncertain action and its panel address', async t => {
  t.mock.timers.enable({apis: ['setTimeout', 'setInterval']});
  const {session,calls,close,mutation}=await controlledSession();
  const original=session.address(),saved=session.save(mutation);
  calls[1]!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'ipc_timeout',message:'Unknown write result'}});
  await new Promise<void>(resolve=>setImmediate(resolve));
  const status={kind:'notebookRuntime',ready:true,pid:1,state:'failed',workspaceID,socketKey};
  const listing=session.workspace({action:'list'});
  calls[2]!.resolve({content:[],structuredContent:{status,workspaces:[]}});await listing;
  assert.equal(await session.workspace({action:'select',id:randomUUID()}),undefined);
  const recovery=session.workspace({action:'retry'});
  assert.deepEqual(calls[3]!.arguments,{action:'retry',id:original.workspaceID});
  const ownerFocus={...sessionSnapshot(),target:{kind:'page',id:randomUUID()}};
  calls[3]!.resolve({content:[],structuredContent:{status:{...status,state:'ready'},workspaces:[],snapshot:ownerFocus}});
  await recovery;
  assert.deepEqual(session.address(),original,'Recovery retains this panel’s page instead of adopting the runtime focus');
  assert.equal(calls[4]!.name,'notebook_panel_edit');
  assert.deepEqual(calls[4]!.arguments,mutation,'Retry keeps the exact accepted action and captured sources');
  calls[4]!.resolve({content:[],structuredContent:{status:'saved',actionID:mutation.actionID}});await saved;
  assert.deepEqual(calls[5]!.arguments.target,original.target);
  calls[5]!.resolve({content:[],structuredContent:sessionSnapshot('2')});
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(session.hasPending,false);assert.equal(session.mutationReady,true);
  await close();
});

test('session closed during handshake suppresses the late connection failure', async t => {
  t.mock.timers.enable({apis: ['setTimeout', 'setInterval']});
  const session = new NotebookSession();
  let rejectConnect!: (error: Error) => void, closes = 0;
  session.app.connect = () => new Promise((_resolve, reject) => {rejectConnect = reject;});
  session.onClose = () => {closes++;};
  const connected = session.connect();
  await session.app.onteardown!({}, {} as never);
  rejectConnect(new Error('Host was closed before initialization'));
  await assert.doesNotReject(connected);
  t.mock.timers.tick(3000);
  assert.equal(closes, 1);
  assert.equal(session.hasAppearance, false);
});

async function openingSession(){
  const session=new NotebookSession();
  const calls:{name:string;arguments:Value;resolve:(value:Awaited<ReturnType<typeof session.app.callServerTool>>)=>void}[]=[];
  const events:string[]=[],runtimes:unknown[]=[];
  let disposed=false,retry:(()=>Promise<void>)|null=null;
  const observe=(value:string)=>{assert.equal(disposed,false,'No callback after teardown');events.push(value);};
  session.app.connect=async()=>{};
  session.app.callServerTool=async input=>new Promise(resolve=>calls.push({name:input.name,arguments:input.arguments!,resolve}));
  session.app.updateModelContext=async()=>({});
  session.onStatus=observe;
  session.onError=(_message,action)=>{observe('error');retry=action;};
  session.onRuntime=value=>{observe('runtime');runtimes.push(value);};
  session.onSnapshot=()=>observe('snapshot');
  session.onClose=()=>{observe('closed');disposed=true;};
  await session.connect();
  return {session,calls,events,runtimes,retry:()=>retry,close:()=>session.app.onteardown!({},{} as never)};
}

test('initial connect keeps exact target and bounds through startup and native opening without workspace transitions',async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,runtimes,close}=await openingSession();
  const request={target:{kind:'page' as const,id:randomUUID()},bounds:{anchor:origin,region:{x:-20,y:30,width:400,height:300}}};
  const snapshot={...sessionSnapshot(),target:request.target};
  session.app.ontoolresult!({content:[],structuredContent:{open:request}});
  assert.equal(calls[0]!.name,'notebook_panel_connect');assert.deepEqual(calls[0]!.arguments,request);
  calls[0]!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'runtime_starting',message:'Starting'}});
  await new Promise<void>(resolve=>setImmediate(resolve));
  t.mock.timers.tick(250);
  assert.equal(calls[1]!.name,'notebook_panel_connect');assert.deepEqual(calls[1]!.arguments,request);
  calls[1]!.resolve({content:[],structuredContent:{runtime:{kind:'notebookRuntime',ready:true,pid:42,state:'opening'}}});
  await new Promise<void>(resolve=>setImmediate(resolve));
  session.app.ontoolresult!({content:[],structuredContent:{open:{target:{kind:'board',id:randomUUID()}}}});
  t.mock.timers.tick(250);
  assert.equal(calls[2]!.name,'notebook_panel_connect');assert.deepEqual(calls[2]!.arguments,request);
  assert.deepEqual(runtimes,[],'An opening workspace does not go through workspace retry or selection');
  calls[2]!.resolve({content:[],structuredContent:snapshot});
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(calls[3]!.name,'notebook_panel_presentation');assert.deepEqual(calls[3]!.arguments.target,request.target);
  calls[3]!.resolve({content:[],structuredContent:snapshot});
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(session.hasAppearance,true);assert.deepEqual(session.snapshot?.target,request.target);
  session.app.ontoolresult!({content:[],structuredContent:{open:{}}});
  assert.equal(calls.length,4,'A second host result cannot redirect the mounted panel');
  await close();
});

for(const afterWait of [false,true])test(`startup failure ${afterWait?'after':'before'} bounded waiting leaves an explicit retry with the same opening request`,async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,retry,close}=await openingSession();
  const request={target:{kind:'page' as const,id:randomUUID()},bounds:{anchor:origin,region:{x:10,y:20,width:500,height:600}}};
  session.app.ontoolresult!({content:[],structuredContent:{open:request}});
  if(afterWait){
    calls[0]!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'runtime_starting',message:'Still starting'}});
    await new Promise<void>(resolve=>setImmediate(resolve));t.mock.timers.tick(250);
  }
  calls.at(-1)!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'runtime_startup_failed',message:'Launch failed'}});
  await new Promise<void>(resolve=>setImmediate(resolve));
  const count=calls.length;t.mock.timers.tick(1000);
  assert.equal(calls.length,count,'A failed startup waits for an explicit retry');
  const action=retry();assert.ok(action);const retried=action();
  assert.deepEqual(calls.at(-1)!.arguments,request);assert.equal(calls.at(-1)!.name,'notebook_panel_connect');
  calls.at(-1)!.resolve({content:[],structuredContent:{...sessionSnapshot(),target:request.target}});
  await retried;assert.deepEqual(session.snapshot?.target,request.target);
  await close();
});

test('closing during startup cancels queued reads and ignores late native admission',async t=>{
  for(const stage of ['waiting','in-flight'] as const)await t.test(stage,async t=>{
    t.mock.timers.enable({apis:['setTimeout','setInterval']});
    const {session,calls,events,close}=await openingSession();
    session.app.ontoolresult!({content:[],structuredContent:{open:{}}});
    if(stage==='waiting'){
      calls[0]!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'runtime_starting',message:'Starting'}});
      await new Promise<void>(resolve=>setImmediate(resolve));
    }
    await close();const after=events.slice();
    if(stage==='in-flight')calls[0]!.resolve({content:[],structuredContent:sessionSnapshot()});
    t.mock.timers.tick(3000);await new Promise<void>(resolve=>setImmediate(resolve));
    assert.equal(calls.length,1);assert.deepEqual(events,after);assert.equal(session.snapshot,undefined);
  });
});

async function connectedPanel(socketPath: string) {
  const server = new McpServer({name: 'panel-contract', version: '1'});
  registerNotebookPanel(server, socketPath, html);
  const client = new Client({name: 'panel-contract', version: '1'});
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  return {client, close: async () => {await client.close(); await server.close();}};
}

/** Separate default and pinned endpoints make accidental routing to the current window observable. */
async function nativeFixture(reply: (endpoint: 'default' | 'pinned', request: Value) => Reply) {
  // macOS Unix socket names are short; the user temp directory can exceed the socket path limit.
  const root = await mkdtemp('/tmp/nb-panel-');
  await chmod(root, 0o700);
  const requests: {endpoint: 'default' | 'pinned'; request: Value}[] = [];
  const sockets = new Set<Socket>();
  const endpoints = ['default', 'pinned'] as const;
  const servers = endpoints.map(endpoint => createServer({allowHalfOpen: true}, socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    let bytes = Buffer.alloc(0), handled = false;
    socket.on('data', part => {
      if (handled) return;
      bytes = Buffer.concat([bytes, Buffer.isBuffer(part) ? part : Buffer.from(part)]);
      if (bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE(0)) return;
      handled = true;
      const envelope = JSON.parse(bytes.subarray(4).toString()) as {version: number; id: string; request: Value};
      assert.equal(envelope.version, 1);
      requests.push({endpoint, request: envelope.request});
      const body = Buffer.from(JSON.stringify({version: 1, id: envelope.id, ...reply(endpoint, envelope.request)}));
      const prefix = Buffer.alloc(4); prefix.writeUInt32BE(body.length);
      socket.end(Buffer.concat([prefix, body]));
    });
  }));
  const paths = [join(root, 'bridge.sock'), join(root, `${socketKey}.sock`)];
  for (const [index, server] of servers.entries()) {
    const path = paths[index]!;
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject); server.listen(path, resolve);
    });
    await chmod(path, 0o600);
  }
  const panel = await connectedPanel(paths[0]!);
  return {...panel, requests, close: async () => {
    await panel.close();
    for (const socket of sockets) socket.destroy();
    await Promise.all(servers.map(server => new Promise<void>((resolve, reject) =>
      server.close(error => error ? reject(error) : resolve()))));
    await rm(root, {recursive: true, force: true});
  }};
}

test('Notebook exposes one HTML app resource, a model opener and app-only gesture tools', async () => {
  const panel = await connectedPanel('/tmp/unused-notebook-panel.sock');
  try {
    const {tools} = await panel.client.listTools();
    assert.deepEqual(tools.map(tool => tool.name).sort(),
      ['notebook_open', 'notebook_panel_connect', 'notebook_panel_edit', 'notebook_panel_presentation', 'notebook_panel_undo', 'notebook_panel_workspace']);
    const opener = tools.find(tool => tool.name === 'notebook_open')!;
    assert.deepEqual(opener._meta?.ui, {resourceUri: panelResourceURI});
    assert.deepEqual(opener._meta?.['openai/ui'], {entrypoints: [{type: 'thread'}, {type: 'global'}]});
    assert.equal(opener.annotations?.readOnlyHint, true);
    for (const tool of tools.filter(tool => tool.name !== 'notebook_open')) {
      assert.deepEqual(tool._meta?.ui, {resourceUri: panelResourceURI, visibility: ['app']});
    }
    const {contents} = await panel.client.readResource({uri: panelResourceURI});
    assert.equal(contents.length, 1);
    assert.equal(contents[0]!.uri, panelResourceURI);
    assert.equal(contents[0]!.mimeType, RESOURCE_MIME_TYPE);
    const resource = contents[0]!;
    assert.ok('text' in resource);
    assert.equal(resource.text, html);
    assert.deepEqual(contents[0]!._meta?.ui,
      {csp: {connectDomains: [], resourceDomains: ['blob:']}, prefersBorder: false});
    assert.deepEqual(contents[0]!._meta?.['openai/ui'],
      {availableDisplayModes: ['fullscreen'], preferredDisplayMode: 'fullscreen'});
  } finally {await panel.close();}
});

test('native presentation stays pinned, bounds pixels and avoids duplicating PNG bytes in text', async () => {
  const heldAsset=randomUUID(),newAsset=randomUUID();
  const appearance={status:'ready',requestID:randomUUID(),sourceRevision:'native-cut',
    camera:{center:origin,scale:.22},viewport:{x:834,y:1194},
    layers:[{id:'held-tile',order:0,assetID:heldAsset},
      {id:'native-ink',order:1,assetID:newAsset,pngBase64:'iVBORw0KGgo-native-png-fixture'}]};
  const view={viewport:{x:834,y:1194},pixelScale:1.5,camera:{center:origin,scale:.22}};
  const known={knownCursor:'42',knownRequestID:randomUUID(),knownAssets:[heldAsset],includeFitBounds:true};
  const value={...address,cursor:'43',elements:[],cards:[],appearance};
  const panel=await nativeFixture(()=>({result:value}));
  try {
    const result=await panel.client.callTool({name:'notebook_panel_presentation',arguments:{...address,appearance:view,...known}});
    assert.notEqual(result.isError,true);
    assert.deepEqual(result.structuredContent,value);
    const text=(result.content[0] as {text:string}).text;
    assert.equal(text.includes(appearance.layers[1]!.pngBase64!),false);
    assert.deepEqual(JSON.parse(text),{workspaceID,target,cursor:'43',status:'ready'});
    assert.deepEqual(panel.requests,[{endpoint:'pinned',request:{command:'panelPresentation',
      panelPresentation:{workspaceID,target,appearance:view,...known}}}]);
    const oversized=await panel.client.callTool({name:'notebook_panel_presentation',arguments:{...address,
      appearance:{viewport:{x:2048,y:2048},pixelScale:3}}});
    assert.equal(oversized.isError,true);
    const excessiveAssets=await panel.client.callTool({name:'notebook_panel_presentation',arguments:{...address,
      appearance:view,knownAssets:Array.from({length:97},()=>randomUUID())}});
    assert.equal(excessiveAssets.isError,true);
    assert.equal(panel.requests.length,1,'Over-budget projection does not enter native preparation');
  } finally {await panel.close();}
});

test('panel gestures keep the admitted endpoint and exact native sources', async () => {
  const cursor = '42', actionID = randomUUID();
  const source = {
    id: 'text-1', kind: 'nativeText', surface: {kind: 'board', ownerID: target.id},
    frame: {x: 20, y: 30, width: 180, height: 90}, worldOrigin: origin, source: 'Чужой текст',
    html: '', css: '', javaScript: '', state: {nested: ['keep', null, {counter: 7}]},
    textStyle: {fontSize: 24, weight: 0.5, red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8},
    parentID: null, basis: null, stamp: {counter: 9, actor: randomUUID()},
    versions: {source: {human: false, observed: {'remote-actor': 8}}},
  };
  const readValue = {...address, cursor, worldOrigin: origin, elements: [{source}],
    cards: [{item: {id: randomUUID(), kind: 'notebook', title: 'Заметки'}, center: origin}],
    rawInkPresent: true, unsupportedElements: [{id: 'ink-1', kind: 'graphic', reason: 'native_graphic'}]};
  const saved = {status: 'saved', actionID, cursor: '43', human: true};
  const undone = {status: 'undone', actionID, cursor: '44'};
  const panel = await nativeFixture((_endpoint, request) => {
    if(request.command==='runtimeStatus')return {result:{kind:'notebookRuntime',ready:true,pid:1,state:'ready',workspaceID,socketKey}};
    if (request.command === 'panelRead') return {result: readValue};
    if (request.command === 'panelEdit') return {result: saved};
    return {result: undone};
  });
  try {
    const opened = await panel.client.callTool({name: 'notebook_panel_connect', arguments: {}});
    assert.notEqual(opened.isError, true);
    assert.deepEqual(opened.structuredContent, readValue);
    assert.deepEqual(JSON.parse((opened.content[0] as {text:string}).text),{workspaceID,target,cursor,status:'ready'},
      'Only structuredContent carries the full initial scene');
    assert.deepEqual(panel.requests, [{endpoint:'default',request:{command:'runtimeStatus'}},
      {endpoint: 'pinned', request: {command: 'panelRead', panelRead: {workspaceID}}}]);

    const edit = {workspaceID, target, actionID, summary: 'Move text',
      operations: [{kind: 'updateElement', target, id: source.id,
        values: {frame: {...source.frame, x: 60}, worldOrigin: origin}}],
      sources: [{id: source.id, spatial: source}, {id: 'new-text'}]};
    const edited = await panel.client.callTool({name: 'notebook_panel_edit', arguments: {...edit, socketKey}});
    assert.deepEqual(edited.structuredContent, saved);
    assert.deepEqual(panel.requests.at(-1), {endpoint: 'pinned', request: {command: 'panelEdit', panelEdit: edit}});
    const retried = await panel.client.callTool({name: 'notebook_panel_edit', arguments: {...edit, socketKey}});
    assert.deepEqual(retried.structuredContent, saved);
    assert.deepEqual(panel.requests.at(-1), panel.requests.at(-2), 'An uncertain response can reuse the same action and sources');

    const itemID=randomUUID(),stackID=randomUUID();
    const placements=[itemID,randomUUID()].map((id,index)=>({itemID:id,heads:[{
      pose:{stackID,center:origin,zIndex:2,stackOrder:index},
      version:{stamp:{counter:9,actor:randomUUID()},human:true,observed:{'remote-actor':8}},
    }]}));
    const move={workspaceID,target,actionID:randomUUID(),summary:'Move cover',
      operations:[{kind:'moveItem',target,id:itemID,values:{center:{...origin,localX:origin.localX+80}}}],
      sources:[{id:itemID,placements}]};
    const moved=await panel.client.callTool({name:'notebook_panel_edit',arguments:{...move,socketKey}});
    assert.notEqual(moved.isError,true);
    assert.deepEqual(panel.requests.at(-1),{endpoint:'pinned',request:{command:'panelEdit',panelEdit:move}},
      'The whole captured stack frontier reaches the native placement owner without rewriting');

    const undo = {workspaceID, target, actionID};
    const result = await panel.client.callTool({name: 'notebook_panel_undo', arguments: {...undo, socketKey}});
    assert.deepEqual(result.structuredContent, undone);
    assert.deepEqual(panel.requests.at(-1), {endpoint: 'pinned', request: {command: 'panelUndo', panelUndo: undo}});
    assert.equal(panel.requests.filter(request => request.endpoint === 'default').length, 1);
  } finally {await panel.close();}
});

test('panel rejects caller routing/authorship fields and preserves the native conflict detail', async () => {
  const conflict = {code: 'revision_conflict', message: 'Captured source changed',
    target, operation: {index: 0, kind: 'updateElement', id: 'text-1'}, currentCursor: '51'};
  const panel = await nativeFixture(() => ({error: conflict}));
  const edit = {...address, actionID: randomUUID(), summary: 'Edit text',
    operations: [{kind: 'updateElement', target, id: 'text-1', values: {source: 'Новый текст'}}],
    sources: [{id: 'text-1', spatial: {id: 'text-1', source: 'Captured text', state: null}}]};
  try {
    for (const input of [{...edit, socketKey: '../outside'}, {...edit, actor: randomUUID()}, {...edit, human: true}]) {
      const refused = await panel.client.callTool({name: 'notebook_panel_edit', arguments: input});
      assert.equal(refused.isError, true);
    }
    assert.equal(panel.requests.length, 0, 'Invalid input never reaches a native owner');
    const result = await panel.client.callTool({name: 'notebook_panel_edit', arguments: edit});
    assert.equal(result.isError, true);
    assert.deepEqual(result.structuredContent, {...conflict, status: 'error'});
    assert.deepEqual(JSON.parse((result.content[0] as {text: string}).text), result.structuredContent);
    assert.equal(panel.requests[0]?.endpoint, 'pinned');
  } finally {await panel.close();}
});

test('workspace bootstrap opens in the same panel without a content owner or desktop window',async()=>{
  let ready=false;
  const id=randomUUID(),status=()=>({kind:'notebookRuntime',ready:true,pid:42,state:ready?'ready':'workspaceRequired',...(ready?{workspaceID,socketKey}:{})});
  const snapshot=sessionSnapshot();
  const open={target,bounds:{anchor:origin,region:{x:-20,y:30,width:500,height:400}}};
  const panel=await nativeFixture((endpoint,request)=>{
    assert.equal(endpoint,request.command==='panelRead'?'pinned':'default');
    if(request.command==='runtimeStatus')return {result:status()};
    if(request.command==='runtimeWorkspace'){
      assert.deepEqual(request.runtimeWorkspace,{action:'create',id,name:'Личное пространство'});
      ready=true;return {result:{status:status(),workspaces:[{id,name:'Личное пространство',local:true,remote:false,deleting:false}]}};
    }
    assert.equal(ready,true,'An empty library must not cause a content read');
    assert.equal(request.command,'panelRead');assert.deepEqual(request.panelRead,{...open,workspaceID});return {result:snapshot};
  });
  try{
    const opened=await panel.client.callTool({name:'notebook_panel_connect',arguments:open});
    assert.notEqual(opened.isError,true);
    assert.deepEqual(opened.structuredContent,{runtime:status()});
    assert.equal(panel.requests.length,1);
    const created=await panel.client.callTool({name:'notebook_panel_workspace',arguments:{action:'create',id,name:'Личное пространство',open}});
    assert.deepEqual((created.structuredContent as Value).snapshot,snapshot);
    assert.equal(panel.requests.length,3);
  }finally{await panel.close();}
});

test('workspace switching retires an old in-flight read and preserves accepted edit ownership',async t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const {session,calls,events,close,mutation}=await controlledSession();
  const read=session.refresh(true);
  const next={...sessionSnapshot('2'),workspaceID:randomUUID(),socketKey:'abcdef0123456789abcdef01'};
  const switching=session.workspace({action:'select',id:next.workspaceID});
  assert.equal(calls[2]!.name,'notebook_panel_workspace');
  calls[2]!.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:1,state:'ready',workspaceID:next.workspaceID,socketKey:next.socketKey},workspaces:[],snapshot:next}});
  await switching;
  calls[1]!.resolve({content:[],structuredContent:sessionSnapshot('old')});await read;
  await new Promise<void>(resolve=>setImmediate(resolve));
  assert.equal(events.filter(value=>value==='snapshot').length,1,'The retiring workspace cannot paint over its successor');
  assert.equal(calls[3]!.arguments.workspaceID,next.workspaceID);
  calls[3]!.resolve({content:[],structuredContent:next});
  await new Promise<void>(resolve=>setImmediate(resolve));
  const write=session.save({...mutation,...session.address()});
  assert.equal(await session.workspace({action:'select',id:workspaceID}),undefined,'An accepted edit owns the session until its result is known');
  assert.equal(calls.at(-1)!.arguments.workspaceID,next.workspaceID);
  await close();await assert.rejects(write,/Панель закрыта/);
});
