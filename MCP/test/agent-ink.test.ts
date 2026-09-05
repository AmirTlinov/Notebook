import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import { actionSchema } from "../src/actions.js";
import { itemID, pageID, rootBoardID, writeFixture } from "./fixture.js";

const target = { kind: "page" as const, id: pageID };
const values = { width: 4, opacity: 0.65, color: { red: 0.1, green: 0.4, blue: 0.8 },
  points: [{ x: 40, y: 50 }, { x: 150, y: 70, width: 2, opacity: 0.35 }] };

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
  const transport = new StdioClientTransport({ command: join(dirname(fileURLToPath(import.meta.url)), "../run.sh"),
    env: { ...getDefaultEnvironment(), NOTEBOOK_HOME: root }, stderr: "pipe" });
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const result = await client.callTool({ name, arguments: args });
    assert.notEqual(result.isError, true, JSON.stringify(result));
    return result.structuredContent as Record<string, any>;
  };
  try {
    await writeFixture(root);
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
    const originalPresence = await readFile(join(root, "last-context.json"), "utf8");
    const saved = await call("notebook_apply", input);
    assert.deepEqual(await call("notebook_apply", input), saved);
    assert.equal(saved.action.results.length, 3);
    assert.ok(saved.action.results.every((r: any) => /^[0-9a-f-]{36}$/i.test(r.id)));
    assert.ok(saved.action.revisions.every((r: any) => r.inkRevision));
    const drawn = await call("notebook_read_page", { page_id: pageID });
    assert.notEqual(drawn.drawingRevision, page.drawingRevision);
    assert.equal(drawn.agentRevision, page.agentRevision);
    assert.deepEqual(drawn.elements, []);
    const raw = JSON.parse(await readFile(join(root, "pages", `${pageID}.json`), "utf8"));
    assert.ok(Buffer.from(raw.drawingData, "base64").subarray(0, 14).toString().startsWith("NotebookInk/1\n"));
    const spatial = JSON.parse(await readFile(join(root, "spatial-ink.json"), "utf8"));
    assert.equal(spatial.actions.length, 2);
    assert.equal(spatial.actions[0].tool, "pen");
    assert.equal(spatial.actions[0].spans[0].samples[1].width, 2);
    assert.equal(spatial.actions[0].spans[0].samples[1].opacity, 0.35);
    const stale = await client.callTool({ name: "notebook_apply", arguments: { ...input, action_id: randomUUID() } });
    assert.equal(stale.isError, true);
    assert.equal((stale.structuredContent as any).code, "revision_conflict");
    const undo = await call("notebook_undo", { action_id: input.action_id });
    assert.equal(undo.action.undo.restored, 3);
    assert.deepEqual(await call("notebook_undo", { action_id: input.action_id }), undo);
    const inactive = JSON.parse(await readFile(join(root, "spatial-ink.json"), "utf8"));
    assert.ok(inactive.actions.every((a: any) => !a.isActive));
    assert.equal(await readFile(join(root, "last-context.json"), "utf8"), originalPresence);
  } finally {
    await client.close();
    await rm(root, { recursive: true, force: true });
  }
});
