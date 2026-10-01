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

type Value = Record<string, unknown>;
type Reply = {result: Value} | {error: Value};
const html = '<!doctype html><html><body>Notebook panel fixture</body></html>';
const socketKey = '0123456789abcdef01234567';
const workspaceID = randomUUID();
const target = {kind: 'board', id: randomUUID()};
const address = {workspaceID, target, socketKey};
const origin = {tileX: 7, tileY: -3, localX: 40, localY: 60};

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
      ['notebook_open', 'notebook_panel_edit', 'notebook_panel_presentation', 'notebook_panel_undo']);
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
  const appearance={status:'ready',requestID:randomUUID(),sourceRevision:'native-cut',
    camera:{center:origin,scale:.22},viewport:{x:834,y:1194},
    layers:[{id:'native-ink',order:1,pngBase64:'iVBORw0KGgo-native-png-fixture'}]};
  const view={viewport:{x:834,y:1194},pixelScale:1.5,camera:{center:origin,scale:.22}};
  const known={knownCursor:'42',knownRequestID:randomUUID()};
  const value={...address,cursor:'43',elements:[],cards:[],appearance};
  const panel=await nativeFixture(()=>({result:value}));
  try {
    const result=await panel.client.callTool({name:'notebook_panel_presentation',arguments:{...address,appearance:view,...known}});
    assert.notEqual(result.isError,true);
    assert.deepEqual(result.structuredContent,value);
    const text=(result.content[0] as {text:string}).text;
    assert.equal(text.includes(appearance.layers[0]!.pngBase64),false);
    assert.deepEqual(JSON.parse(text),{workspaceID,target,cursor:'43',status:'ready'});
    assert.deepEqual(panel.requests,[{endpoint:'pinned',request:{command:'panelPresentation',
      panelPresentation:{workspaceID,target,appearance:view,...known}}}]);
    const oversized=await panel.client.callTool({name:'notebook_panel_presentation',arguments:{...address,
      appearance:{viewport:{x:2048,y:2048},pixelScale:2}}});
    assert.equal(oversized.isError,true);
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
  const panel = await nativeFixture((endpoint, request) => {
    if (endpoint === 'default') return {result: readValue};
    if (request.command === 'panelEdit') return {result: saved};
    return {result: undone};
  });
  try {
    const opened = await panel.client.callTool({name: 'notebook_open', arguments: {}});
    assert.notEqual(opened.isError, true);
    assert.deepEqual(opened.structuredContent, readValue);
    assert.deepEqual(panel.requests, [{endpoint: 'default', request: {command: 'panelRead', panelRead: {}}}]);

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
