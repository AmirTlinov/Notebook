import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import { appActor, itemID, pageID, rootBoardID, writeFixture } from "./fixture.js";
import { documentSpatialSize } from "../src/domain.js";

const mcpRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = await mkdtemp(join(tmpdir(), "notebook-bridge-smoke-"));
const client = new Client({ name: "notebook-collaboration-proof", version: "0.1.0" });
const transport = new StdioClientTransport({ command: join(mcpRoot, "run.sh"),
  env: { ...getDefaultEnvironment(), NOTEBOOK_HOME: root }, stderr: "pipe" });
type Data = Record<string, any>;
const checked: string[] = [];
async function call(name: string, args: Data = {}): Promise<Data> {
  const result = await client.callTool({ name, arguments: args });
  assert.notEqual(result.isError, true, JSON.stringify(result.structuredContent ?? result.content));
  return result.structuredContent as Data;
}
async function rejected(name: string, args: Data, code: string) {
  const result = await client.callTool({ name, arguments: args });
  assert.equal(result.isError, true);
  assert.equal((result.structuredContent as Data).code, code, JSON.stringify(result));
}
const board = (id = rootBoardID) => ({ kind: "board", id });
const page = { kind: "page", id: pageID };
const point = { tileX: 0, tileY: 0, localX: 500, localY: 500 };
const frame = { x: 30, y: 40, width: 300, height: 180 };
async function boardExpectations(id = rootBoardID) {
  const read = await call("notebook_read_board", { board_id: id });
  return [{ target: board(id), revision: read.boardRevision },
    { target: { kind: "workspace", id: rootBoardID }, revision: read.workspaceRevision }];
}
async function pageExpectation() {
  const read = await call("notebook_read_page", { page_id: pageID, include_source: true });
  return [{ target: page, revision: read.agentRevision }];
}
async function apply(operations: Data[], expected: Data[], actionID = randomUUID()) {
  return call("notebook_apply", { action_id: actionID, summary: "Общий законченный ход", expected, operations });
}

try {
  await writeFixture(root);
  await client.connect(transport);
  const tools = (await client.listTools()).tools;
  assert.ok(tools.some(t => t.name === "notebook_apply" && t.annotations?.idempotentHint));
  assert.ok(!tools.some(t => /notebook_(put_|patch_document|create_|remove_|move_nodes|stack_nodes|rename_item)/.test(t.name)));
  checked.push("one mutation owner and typed MCP interface");
  const observation = await client.callTool({ name: "notebook_observe", arguments: {} });
  assert.ok(observation.content.some(c => c.type === "image"),JSON.stringify(observation.structuredContent));
  assert.ok((observation.structuredContent as Data).visibleItems);
  const ink = await call("notebook_page_map", { page_id: pageID });
  assert.equal(ink.regions.length, 1);
  const detail = await client.callTool({ name: "notebook_render_regions", arguments: {
    page_id: pageID, expected_drawing_revision: ink.drawingRevision, region_ids: [ink.regions[0].id], mode: "ink" } });
  assert.notEqual(detail.isError, true, JSON.stringify(detail));
  checked.push("settled view and faithful visible ink regions");

  const firstExpectation = await pageExpectation();
  const actionID = randomUUID();
  const operations = [{ kind: "insertElement", target: page, id: "counter", values: {
    kind: "web", source: "<button>+</button>", frame, state: { count: 7 }, javaScript: "window.count = 7;" } },
    { kind: "insertElement", target: page, id: "meaning", values: { kind: "markdown", source: "# Meaning", frame: { ...frame, y: 300 } } }];
  const first = await apply(operations, firstExpectation, actionID);
  assert.deepEqual(await apply(operations, firstExpectation, actionID), first);
  await rejected("notebook_apply", { action_id: actionID, summary: "Different", expected: firstExpectation, operations }, "action_id_conflict");
  await rejected("notebook_apply", { action_id: randomUUID(), summary: "Stale", expected: firstExpectation, operations }, "revision_conflict");
  await apply([{ kind: "updateElement", target: page, id: "counter", values: { css: "button { color: blue }" } }], await pageExpectation());
  let content = await call("notebook_read_page", { page_id: pageID, include_source: true });
  assert.deepEqual(content.elements.find((e: Data) => e.id === "counter").state, { count: 7 });
  assert.match(content.elements.find((e: Data) => e.id === "meaning").html, /<h1>Meaning/);
  const compact = await call("notebook_read_page", {page_id:pageID});
  assert.equal(compact.elements[0].source, undefined);
  await rm(join(root,"previews","current-view.png"));
  const pendingView = await call("notebook_observe", {since:(observation.structuredContent as Data).cursor});
  assert.equal(pendingView.visual.status,"pending");
  assert.ok(pendingView.content);
  assert.ok(pendingView.changes.changed.length);
  const pointing = await call("notebook_point", {target:page,element_id:"meaning",label:"Я вижу заголовок мысли"});
  assert.equal(pointing.attention.reference.target.id.toLowerCase(),pageID.toLowerCase());
  const search = await call("notebook_search",{query:"Meaning"});
  assert.ok(search.results.some((r:Data) => r.elementID === "meaning" && r.reference.revision));
  const targetRender = await call("notebook_render",{target:page,expected_revision:content.agentRevision});
  assert.equal(targetRender.status,"pending");
  await rejected("notebook_render",{target:page,expected_revision:"0@00000000-0000-0000-0000-000000000000"},"revision_conflict");
  checked.push("compact reads, useful pending observation, stable pointer, search and targeted render request");
  checked.push("atomic batch, idempotency, explicit conflicts and preserved state");

  const edited = await apply([{ kind: "updateElement", target: page, id: "meaning", values: { source: "Changed", css: "p { color: red }" } }], await pageExpectation());
  const pagePath = join(root, "pages", `${pageID}.json`);
  const humanPage = JSON.parse(await readFile(pagePath, "utf8"));
  const meaning = humanPage.elements.find((e: Data) => e.id === "meaning");
  meaning.source = "Human understanding"; meaning.html = "Human understanding";
  humanPage.agentStamp = { counter: humanPage.agentStamp.counter + 1, actor: appActor };
  await writeFile(pagePath, JSON.stringify(humanPage));
  const continued = await call("notebook_action",{action_id:edited.action.id});
  assert.ok(continued.action.continuations.length >= 2);
  const interpretation = await call("notebook_point",{target:page,element_id:"meaning",
    source_revision:pointing.attention.reference.revision,label:"Я рассматриваю исходный заголовок"});
  assert.equal(interpretation.attention.reference.revision,pointing.attention.reference.revision);
  const reconsider = await call("notebook_observe");
  assert.equal(reconsider.references.find((r:Data)=>r.author === "agent").status,"changed");
  const undone = await call("notebook_undo", { action_id: edited.action.id });
  assert.ok(undone.action.undo.preserved.length >= 2);
  assert.deepEqual(await call("notebook_undo", { action_id: edited.action.id }), undone);
  content = await call("notebook_read_page", { page_id: pageID, include_source: true });
  assert.equal(content.elements.find((e: Data) => e.id === "meaning").source, "Human understanding");
  assert.equal(content.elements.find((e: Data) => e.id === "meaning").css, "");
  checked.push("one undo retains the later human meaning");

  const a = randomUUID(), b = randomUUID();
  await apply([a, b].map(id => ({ kind: "createBoard", target: board(), id, values: { center: point } })), await boardExpectations());
  const readA = await call("notebook_read_board", { board_id: a });
  const readB = await call("notebook_read_board", { board_id: b });
  assert.equal(readA.boardRevision, readB.boardRevision);
  const presencePath = join(root, "last-context.json");
  const presence = JSON.parse(await readFile(presencePath, "utf8"));
  await writeFile(presencePath, JSON.stringify({ ...presence, mode: "board", openProgress: 0, focusedItemID: undefined, boardID: b }));
  await apply([{ kind: "insertElement", target: board(a), id: "belongs-to-a", values: {
    kind: "markdown", source: "A", frame, worldOrigin: point } }], [{ target: board(a), revision: readA.boardRevision }]);
  assert.equal((await call("notebook_read_board", { board_id: a })).elements.length, 1);
  assert.equal((await call("notebook_read_board", { board_id: b })).elements.length, 0);
  checked.push("board identity survives a human camera change and equal revisions");

  for (const paper of ["a4", "letter"] as const) {
    const id = randomUUID();
    const target = { kind: "document", id };
    await apply([{ kind: "createDocument", target: board(), id, values: { center: point, paperSize: paper,
      title: "", preamble: "\\newcommand{\\meaning}{M}", blocks: [
        { id: "first", kind: "markdown", source: "First" }, { id: "second", kind: "markdown", source: "Second" },
        { id: "live", kind: "interactive", html: "<button>+</button>", initialState: { count: 1 } }] } }], await boardExpectations());
    const read = await call("notebook_read_document", { document_id: id });
    await apply([{ kind: "updateBlock", target, id: "first", values: { source: "Edited first" } },
      { kind: "reorderBlocks", target, values: { ids: ["second", "first", "live"] } }], [{ target, revision: read.contentRevision }]);
    const source = await call("notebook_read_document", { document_id: id, include_source: true });
    assert.deepEqual(source.blocks.map((v: Data) => v.id), ["second", "first", "live"]);
    assert.equal(source.preamble, "\\newcommand{\\meaning}{M}");
    const size = documentSpatialSize(paper);
    const cover = { kind: "cover", id, boardID: rootBoardID };
    const readBoard = await call("notebook_read_board", { board_id: rootBoardID });
    await apply([{ kind: "insertElement", target: cover, id: `corner-${paper}`, values: { kind: "markdown", source: "Corner",
      frame: { x: size.width - 100, y: size.height - 80, width: 100, height: 80 } } }], [{ target: cover, revision: readBoard.boardRevision }]);
    const changedBoard = await call("notebook_read_board", { board_id: rootBoardID });
    await rejected("notebook_apply", { action_id: randomUUID(), summary: "Outside", expected: [{ target: cover, revision: changedBoard.boardRevision }], operations: [
      { kind: "updateElement", target: cover, id: `corner-${paper}`, values: { frame: { x: size.width - 99, y: 20, width: 100, height: 80 } } }] }, "invalid_operation");
  }
  const workspace = JSON.parse(await readFile(join(root, "workspace.json"), "utf8"));
  assert.equal(workspace.selectedItemID.toLowerCase(), itemID);
  checked.push("block-local edits, physical A4/Letter cover bounds and human selection");
  console.log(JSON.stringify({ status: "passed", scenarios: checked }, null, 2));
} finally {
  await client.close();
  await rm(root, { recursive: true, force: true });
}
