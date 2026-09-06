import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { BridgeError, runBridge } from "../src/bridge.js";
import { appActor, pageID, writeFixture } from "./fixture.js";

test("the native reference and render routes do not load a different page in the same notebook", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-reference-"));
  try {
    await writeFixture(root);
    const otherID = "7e7a0000-0000-4000-8000-000000000099";
    const workspace = JSON.parse(await readFile(join(root, "workspace.json"), "utf8"));
    const page = JSON.parse(await readFile(join(root, "pages", `${pageID}.json`), "utf8"));
    workspace.items[0].pageIDs.push(otherID);
    await writeFile(join(root, "workspace.json"), JSON.stringify(workspace));
    await writeFile(join(root, "pages", `${otherID}.json`), JSON.stringify({ ...page, id: otherID }));
    const target = { kind: "page", id: pageID };
    const before = await runBridge<{ revision: string }>(root, { command: "reference", target });
    // The one-time migration has completed; only the requested owner may now be read.
    await writeFile(join(root, "pages", `${otherID}.json`), "Unrelated unreadable source");
    const input = { command: "render", target, expectedRevision: `0@${appActor}` };
    const request = await runBridge<{ id: string; sourceRevision: string }>(root, input);
    assert.equal(request.sourceRevision, before.revision);
    assert.deepEqual(await runBridge(root, input), request);
    assert.deepEqual(await runBridge(root, { command: "reference", target }), before);
    await assert.rejects(runBridge(root, { ...input, expectedRevision: `99@${appActor}` }), error => {
      assert.ok(error instanceof BridgeError);
      assert.equal(error.detail.code, "revision_conflict");
      return true;
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
