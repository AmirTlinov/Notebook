import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import { NotebookStore } from "../src/store.js";
import { actionSchema } from "../src/actions.js";
import { itemID, pageID, rootBoardID, appActor, writeFixture, fixtureSocket, fixtureControl, stopFixture } from "./fixture.js";

const target = { kind: "page" as const, id: pageID };
const values = { width: 4, opacity: 0.65, color: { red: 0.1, green: 0.4, blue: 0.8 },
  points: [{ x: 40, y: 50 }, { x: 150, y: 70, width: 2, opacity: 0.35 }] };

test("stdio code notes share the native journal, exact material and causal undo without moving paper", {timeout:60_000}, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-code-pen-"));
  const client = new Client({name:"code-pen-proof",version:"1.0.0"});
  const call = async (name:string, args:Record<string,unknown>) => {
    const result = await client.callTool({name,arguments:args});
    assert.notEqual(result.isError,true,JSON.stringify(result));
    return result.structuredContent as Record<string,any>;
  };
  try {
    await writeFixture(root);
    const file = {computer:randomUUID(),project:"fixture",root:"/project",path:"example.py"};
    const text = "print(4)\n", id = randomUUID();
    const fragment = {id,file,sourceHash:createHash("sha256").update(text).digest("hex"),utf16Offset:0,
      text,width:600,height:400,fontSize:15,stamp:{counter:1,actor:appActor}};
    await fixtureControl(root,"codeFragment",fragment);
    await client.connect(new StdioClientTransport({command:join(dirname(fileURLToPath(import.meta.url)),"../run.sh"),
      env:{...getDefaultEnvironment(),NOTEBOOK_SOCKET:fixtureSocket(root)},stderr:"pipe"}));
    const store = new NotebookStore(fixtureSocket(root)), presence = await store.readPresence();
    const list = await call("notebook_read_code_notes",{read:"file",file});
    assert.equal(list.fragments.length,1);
    assert.equal(list.fragments[0].id.toLowerCase(),id);
    assert.deepEqual((await call("notebook_read_code_notes",{read:"file",file:{...file,computer:randomUUID()}})).fragments,[]);
    const before = await call("notebook_read_code_notes",{read:"fragment",fragment_id:id});
    const target = {kind:"codeFragment",id};
    const action = {action_id:randomUUID(),summary:"Подчеркнуть рассмотренный код",expected:[{target,revision:before.revision,inkRevision:before.inkRevision}],
      operations:[{kind:"appendInkStroke",target,values}]};
    const saved = await call("notebook_apply",action);
    assert.deepEqual(await call("notebook_apply",action),saved);
    assert.equal(saved.action.results.length,1);
    assert.equal(saved.action.results[0].target.kind,"codeFragment");
    const after = await call("notebook_read_code_notes",{read:"fragment",fragment_id:id});
    assert.equal(after.fragment.text,text);
    assert.equal(after.revision,before.revision);
    assert.notEqual(after.inkRevision,before.inkRevision);
    assert.equal(after.ink.actions.length,1);
    assert.equal(after.ink.actions[0].spans[0].surface.kind,"codeFragment");
    assert.equal(after.ink.actions[0].spans[0].samples.length,2);
    await call("notebook_undo",{action_id:action.action_id});
    const undone = await call("notebook_read_code_notes",{read:"fragment",fragment_id:id});
    assert.equal(undone.ink.actions[0].isActive,false);
    assert.equal(undone.ink.actions[0].id,after.ink.actions[0].id);
    assert.deepEqual(await store.readPresence(),presence);
    const missing = await client.callTool({name:"notebook_read_code_notes",arguments:{read:"fragment",fragment_id:randomUUID()}});
    assert.equal(missing.isError,true);
    assert.equal((missing.structuredContent as any).code,"target_missing");
  } finally { await client.close(); await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});

test("native pen schema bounds points, width, opacity and immutable stroke IDs", () => {
  const operation = { kind: "appendInkStroke", target, values };
  const input = { action_id: randomUUID(), summary: "Ручкой", expected: [{ target, revision: "0@actor", inkRevision: "0@actor" }], operations: [operation] };
  assert.equal(actionSchema.safeParse(input).success, true);
  for (const patch of [{ points: [] }, { width: 0 }, { opacity: 2 }, { points: [{ x: 0, y: Infinity }] },
    { points: Array(8193).fill({ x: 10, y: 20 }) }]) {
    assert.equal(actionSchema.safeParse({ ...input, operations: [{ ...operation, values: { ...values, ...patch } }] }).success, false);
  }
});

test("stdio native pen writes existing owners, pins ink, retries once and undoes its UUIDs", { timeout: 60_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-native-pen-"));
  const client = new Client({ name: "native-pen-proof", version: "1.0.0" });

  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const result = await client.callTool({ name, arguments: args });
    assert.notEqual(result.isError, true, JSON.stringify(result));
    return result.structuredContent as Record<string, any>;
  };
  try {
    await writeFixture(root);
  const transport = new StdioClientTransport({ command: join(dirname(fileURLToPath(import.meta.url)), "../run.sh"),
    env: { ...getDefaultEnvironment(), NOTEBOOK_SOCKET: fixtureSocket(root) }, stderr: "pipe" });
    await client.connect(transport);
    const page = await call("notebook_read_page", { page_id: pageID });
    const board = await call("notebook_read_board", { board_id: rootBoardID });
    const cover = { kind: "cover", id: itemID, boardID: rootBoardID };
    const boardTarget = { kind: "board", id: rootBoardID };
    const input = { action_id: randomUUID(), summary: "Три штриха настоящей ручкой", expected: [
      { target, revision: page.agentRevision, inkRevision: page.drawingRevision },
      { target: boardTarget, revision: board.boardRevision, inkRevision: board.spatialInkRevision },
      { target: cover, revision: board.boardRevision, inkRevision: board.spatialInkRevision },
    ], operations: [
      { kind: "appendInkStroke", target, values },
      { kind: "appendInkStroke", target: boardTarget, values: { ...values, worldOrigin: { tileX: 10000, tileY: -10000, localX: 10, localY: 20 } } },
      { kind: "appendInkStroke", target: cover, values },
    ] };
    const store=new NotebookStore(fixtureSocket(root));
    const originalPresence=await store.readPresence();
    const saved = await call("notebook_apply", input);
    assert.deepEqual(await call("notebook_apply", input), saved);
    assert.equal(saved.action.results.length, 3);
    assert.ok(saved.action.results.every((r: any) => /^[0-9a-f-]{36}$/i.test(r.id)));
    assert.ok(saved.action.revisions.every((r: any) => r.inkRevision));
    const drawn = await call("notebook_read_page", { page_id: pageID });
    assert.notEqual(drawn.drawingRevision, page.drawingRevision);
    assert.equal(drawn.agentRevision, page.agentRevision);
    assert.deepEqual(drawn.elements, []);
    const raw = await store.readPage(pageID);
    const pageInkBytes = Buffer.from(raw.drawingData, "base64");
    assert.equal(pageInkBytes.subarray(0, 14).toString(), "NotebookInk/2\n");
    const pageInk = JSON.parse(pageInkBytes.subarray(14).toString());
    assert.equal(pageInk.actions.length, 1);
    assert.match(pageInk.actions[0].id, /^[0-9a-f-]{36}$/i);
    assert.equal(pageInk.actions[0].sequence, 1);
    assert.equal(pageInk.actions[0].isActive, true);
    assert.equal(pageInk.actions[0].tool, "pen");
    assert.equal(pageInk.actions[0].samples.length, values.points.length);
    const spatial = await store.readSpatialInk([{kind:"board",ownerID:rootBoardID},{kind:"cover",ownerID:itemID}]);
    assert.equal(spatial.actions.length, 2);
    assert.equal(spatial.actions[0]!.tool, "pen");
    assert.equal(spatial.actions[0]!.spans[0]!.samples[1]!.width, 2);
    assert.equal(spatial.actions[0]!.spans[0]!.samples[1]!.opacity, 0.35);
    const stale = await client.callTool({ name: "notebook_apply", arguments: { ...input, action_id: randomUUID() } });
    assert.equal(stale.isError, true);
    assert.equal((stale.structuredContent as any).code, "revision_conflict");
    const undo = await call("notebook_undo", { action_id: input.action_id });
    assert.equal(undo.action.undo.restored, 3);
    assert.deepEqual(await call("notebook_undo", { action_id: input.action_id }), undo);
    const inactive = await store.readSpatialInk([{kind:"board",ownerID:rootBoardID},{kind:"cover",ownerID:itemID}]);
    assert.ok(inactive.actions.every((a: any) => !a.isActive));
    const undonePage = await store.readPage(pageID);
    const undoneBytes = Buffer.from(undonePage.drawingData, "base64");
    assert.equal(undoneBytes.subarray(0, 14).toString(), "NotebookInk/2\n");
    const undoneInk = JSON.parse(undoneBytes.subarray(14).toString());
    assert.deepEqual(undoneInk.actions, [{ ...pageInk.actions[0], isActive: false }],
      "Undo retains the page stroke's UUID, sequence and immutable samples");
    assert.deepEqual(await store.readPresence(), originalPresence);
  } finally {
    await client.close();
    await stopFixture(root);
    await rm(root, { recursive: true, force: true });
  }
});
