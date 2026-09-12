import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import { NotebookStore } from "../src/store.js";
import { fixtureControl, fixtureSocket, itemID, rootBoardID, stopFixture, writeFixture } from "./fixture.js";

test("stdio board, cover and observation expose the complete native cut after a lower-clock move", { timeout: 60_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-board-content-"));
  const client = new Client({ name: "complete-board-cut", version: "1.0.0" });
  const call = async (name: string, args: Record<string, unknown>) => {
    const result = await client.callTool({ name, arguments: args });
    assert.notEqual(result.isError, true, JSON.stringify(result));
    return result.structuredContent as Record<string, any>;
  };
  try {
    await writeFixture(root);
    const destination = { tileX: 0, tileY: 0, localX: 120, localY: 140 };
    const beforeStamp = await fixtureControl(root, "prepareLowerClockBoardMove", destination);
    await client.connect(new StdioClientTransport({
      command: join(dirname(fileURLToPath(import.meta.url)), "../run.sh"),
      env: { ...getDefaultEnvironment(), NOTEBOOK_SOCKET: fixtureSocket(root) }, stderr: "pipe",
    }));
    const store = new NotebookStore(fixtureSocket(root));
    const addressed = await store.read<any>({ kind: "boardItem", id: itemID });
    assert.equal(addressed.board.format, 3);
    assert.ok(Array.isArray(addressed.board.placements));
    assert.equal(addressed.board.freeItems[0].itemID.toLowerCase(), itemID);
    assert.deepEqual(addressed.board.stacks, []);
    const working = await store.read<any>({ kind: "workingSet", itemIDs: [itemID], boardIDs: [rootBoardID] });
    assert.ok(working.boards.every((node: any) => Array.isArray(node.board.freeItems) && Array.isArray(node.board.stacks)));
    const canonical = (await fixtureControl(root, "readFixture")).board.boards[0].board;
    assert.ok(Array.isArray(canonical.placements));
    assert.equal(canonical.freeItems, undefined, "Derived read layout never becomes a second persistent owner");
    assert.equal(canonical.stacks, undefined);
    const bounds = { anchor: { tileX: 0, tileY: 0, localX: 1000, localY: 1000 },
      region: { x: 0, y: 0, width: 1, height: 1 } };
    const read = { board_id: rootBoardID, bounds, limit: 1 };
    const before = await call("notebook_read_board", read);
    assert.deepEqual(before.nodes, []);
    assert.deepEqual(before.elements, []);
    assert.equal(before.boardRevision, await store.readBoardContentRevision(rootBoardID),
      "An empty bounded response still carries the whole board's native precondition");
    assert.equal((await call("notebook_read_notebook", { notebook_id: itemID })).boardRevision, before.boardRevision);
    const observed = await call("notebook_observe", { wait_ms: 0 });
    assert.equal(observed.revisions.board, before.boardRevision);

    const afterStamp = await fixtureControl(root, "commitLowerClockBoardMove");
    assert.deepEqual(afterStamp, beforeStamp, "The largest clock is deliberately unchanged by the concurrent placement");
    const after = await call("notebook_read_board", read);
    assert.notEqual(after.boardRevision, before.boardRevision);
    assert.equal(after.boardRevision, await store.readBoardContentRevision(rootBoardID));
    assert.deepEqual(after.nodes, []);
    assert.deepEqual(after.elements, []);
    const notebook = await call("notebook_read_notebook", { notebook_id: itemID });
    assert.equal(notebook.boardRevision, after.boardRevision);
    assert.deepEqual(notebook.placement.center, destination);
    const changed = await call("notebook_observe", { wait_ms: 0, since: observed.cursor });
    assert.equal(changed.revisions.board, after.boardRevision);
    assert.equal(changed.boardID.toLowerCase(), rootBoardID);
    assert.ok(changed.changes.changed.includes(`board:${changed.boardID}`));

    const targets = [{ kind: "board", id: rootBoardID }, { kind: "cover", id: itemID, boardID: rootBoardID }];
    const operations = targets.map((target, index) => ({ kind: "insertElement", target, id: `cut-note-${index}`,
      values: { kind: "markdown", source: "Reviewed complete content", frame: { x: 0, y: 0, width: 120, height: 40 },
        ...(target.kind === "board" ? { worldOrigin: { tileX: 0, tileY: 0, localX: 0, localY: 0 } } : {}) } }));
    for (const [index, target] of targets.entries()) {
      const rejected = await client.callTool({ name: "notebook_apply", arguments: {
        action_id: randomUUID(), summary: "Не применять старый прочитанный срез",
        expected: [{ target, revision: before.boardRevision }], operations: [operations[index]],
      } });
      assert.equal(rejected.isError, true);
      assert.equal((rejected.structuredContent as any).code, "revision_conflict");
    }
    assert.equal(await store.readBoardContentRevision(rootBoardID), after.boardRevision);
    const saved = await call("notebook_apply", { action_id: randomUUID(), summary: "Пометки на принятом содержимом",
      expected: targets.map(target => ({ target, revision: after.boardRevision })), operations });
    const committed = await store.readBoardContentRevision(rootBoardID);
    assert.notEqual(committed, after.boardRevision);
    assert.equal(saved.action.revisions.length, 1, "Both edits belong to one physical board content owner");
    assert.equal(saved.action.revisions[0].target.kind, "board");
    assert.equal(saved.action.revisions[0].target.id.toLowerCase(), rootBoardID);
    assert.equal(saved.action.revisions[0].revision, committed,
      "The receipt names the post-publication native content, not the earlier bounded projection");
    assert.equal((await call("notebook_read_notebook", { notebook_id: itemID })).boardRevision, committed);
  } finally {
    await client.close();
    await stopFixture(root);
    await rm(root, { recursive: true, force: true });
  }
});
