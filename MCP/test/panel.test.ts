import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {chmod, mkdtemp, rm} from 'node:fs/promises';
import {createServer, type Socket} from 'node:net';
import {join} from 'node:path';
import {Client, InMemoryTransport} from '@modelcontextprotocol/client';
import {McpServer} from '@modelcontextprotocol/server';
import {RESOURCE_MIME_TYPE} from '@modelcontextprotocol/ext-apps/server';
import {panelResourceURI, registerNotebookPanel} from '../src/panel-tools.js';
import {NotebookSession} from '../panel/session.js';
import type {PanelMutation, PanelSnapshot} from '../panel/model.js';

type Value = Record<string, unknown>;
type Reply = {result: Value} | {error: Value};
const html = '<!doctype html><html><body>Notebook panel fixture</body></html>';
const socketKey = '0123456789abcdef01234567';
const workspaceID = randomUUID();
const target = {kind: 'board', id: randomUUID()};
const address = {workspaceID, target, socketKey};
const origin = {tileX: 7, tileY: -3, localX: 40, localY: 60};

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

for(const code of ['ipc_timeout','operation_failed'])test(`error Retry repairs ${code} before repeating the same text action`, async t => {
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
      ['notebook_open', 'notebook_panel_edit', 'notebook_panel_presentation', 'notebook_panel_undo', 'notebook_panel_workspace']);
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
    const opened = await panel.client.callTool({name: 'notebook_open', arguments: {}});
    assert.notEqual(opened.isError, true);
    assert.deepEqual(opened.structuredContent, readValue);
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
  const panel=await nativeFixture((endpoint,request)=>{
    assert.equal(endpoint,request.command==='panelRead'?'pinned':'default');
    if(request.command==='runtimeStatus')return {result:status()};
    if(request.command==='runtimeWorkspace'){
      assert.deepEqual(request.runtimeWorkspace,{action:'create',id,name:'Личное пространство'});
      ready=true;return {result:{status:status(),workspaces:[{id,name:'Личное пространство',local:true,remote:false,deleting:false}]}};
    }
    assert.equal(ready,true,'An empty library must not cause a content read');
    assert.equal(request.command,'panelRead');return {result:snapshot};
  });
  try{
    const opened=await panel.client.callTool({name:'notebook_open',arguments:{}});
    assert.notEqual(opened.isError,true);
    assert.deepEqual(opened.structuredContent,{runtime:status()});
    assert.equal(panel.requests.length,1);
    const created=await panel.client.callTool({name:'notebook_panel_workspace',arguments:{action:'create',id,name:'Личное пространство'}});
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
