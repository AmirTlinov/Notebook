import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { actionSchema } from "../src/actions.js";
import { publicPage, revision } from "../src/domain.js";
import { NotebookStore } from "./native-client.js";
import { writeFixture, fixtureSocket, stopFixture, pageID } from "./fixture.js";

test("native IPC exposes editable geometry to the agent and causally undoes edit, deletion and conversion", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-graphic-ipc-"));
  try {
    await writeFixture(root);
    const store = new NotebookStore(fixtureSocket(root)), target = { kind: "page", id: pageID };
    const sourceID = randomUUID();
    async function action(kind: string, id: string, values: unknown) {
      const page = await store.readPage(pageID), actionID = randomUUID();
      const action = actionSchema.parse({ summary: kind, references: [],
        expected: [{ target, revision: revision(page.agentStamp), inkRevision: revision(page.drawingStamp) }],
        operations: [{ kind, target, id, values }] });
      await assert.doesNotReject(store.command({ command: "apply", action: { ...action, id: actionID } }), kind);
      return actionID;
    }
    await action("appendInkStroke", sourceID, { points: Array.from({ length: 49 }, (_, i) => ({
      x: 150 + 60 * Math.cos(i / 48 * 2 * Math.PI), y: 150 + 60 * Math.sin(i / 48 * 2 * Math.PI),
    })) });
    const raw = (await store.readPage(pageID)).drawingData;
    const converted = await action("convertInkToElement", "circle", { kind: "graphic", source: "",
      frame: { x: 90, y: 90, width: 120, height: 120 }, graphic: { shape: "ellipse", label: "",
        style: { stroke: { red: 0, green: 0, blue: 0 }, strokeWidth: 2 }, representation: "geometry", visible: true, sourceInkIDs: [sourceID] } });
    const edit = await action("updateElement", "circle", { graphic: { label: "1:2" } });
    const read = publicPage(await store.readPage(pageID)) as { elements: Array<{ id: string; graphic: { label: string } }> };
    assert.equal(read.elements.find(x => x.id === "circle")?.graphic.label, "1:2");
    const deleted = await action("removeElement", "circle", {});
    assert.equal((await store.readPage(pageID)).elements.find(x => x.id === "circle")?.graphic?.visible, false);
    for (const [step, actionID] of [["deletion", deleted], ["edit", edit], ["conversion", converted]])
      await assert.doesNotReject(store.command({ command: "undo", actionID }), `undo ${step}`);
    const page = await store.readPage(pageID), graphic = page.elements.find(x => x.id === "circle")?.graphic;
    assert.equal(graphic?.representation, "ink"); assert.equal(graphic?.visible, true);
    assert.equal(graphic?.label, ""); assert.equal(page.drawingData, raw);
  } finally { await stopFixture(root); await rm(root, { recursive: true, force: true }); }
});
