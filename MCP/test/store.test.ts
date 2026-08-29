import assert from "node:assert/strict";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import type { AgentElement } from "../src/domain.js";
import { revision } from "../src/domain.js";
import { ConflictError, StoreError, TetradStore } from "../src/store.js";
import { appActor, pageID, writeFixture } from "./fixture.js";

async function withStore(
  body: (store: TetradStore, root: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "tetrad-mcp-"));
  try {
    await writeFixture(root);
    await body(new TetradStore(root), root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("reads the page selected by the native workspace", async () => {
  await withStore(async (store) => {
    const selected = await store.readSelected();
    assert.equal(selected.page.id, pageID);
    assert.equal(revision(selected.page.agentStamp), `0@${appActor}`);
  });
});

test("atomically replaces one element and advances its agent stamp", async () => {
  await withStore(async (store, root) => {
    const element: AgentElement = {
      id: "answer",
      kind: "markdown",
      frame: { x: 40, y: 50, width: 300, height: 200 },
      source: "# Ответ",
      html: "<h1>Ответ</h1>",
      css: "",
      javaScript: "",
      state: {},
    };
    const changed = await store.replaceElements({
      pageID: undefined,
      expectedRevision: `0@${appActor}`,
      transform: () => [element],
    });
    assert.deepEqual(changed.elements, [element]);
    assert.equal(changed.agentStamp.counter, 1);
    assert.notEqual(changed.agentStamp.actor, appActor);
    assert.match(changed.agentStamp.actor, /^[0-9a-f-]{36}$/);
    assert.deepEqual(
      (await readdir(join(root, "pages"))).filter((name) => name.endsWith(".tmp")),
      [],
    );
    assert.deepEqual((await store.readPage(pageID)).elements, [element]);
  });
});

test("rejects a stale writer instead of erasing a newer interactive state", async () => {
  await withStore(async (store) => {
    const first = store.replaceElements({
      pageID: pageID,
      expectedRevision: `0@${appActor}`,
      transform: () => [],
    });
    // No content change keeps the revision stable.
    assert.equal((await first).agentStamp.counter, 0);
    await store.replaceElements({
      pageID,
      expectedRevision: `0@${appActor}`,
      transform: () => [{
        id: "new",
        kind: "web",
        frame: { x: 0, y: 0, width: 100, height: 100 },
        source: "<button>+</button>",
        html: "<button>+</button>",
        css: "",
        javaScript: "",
        state: { count: 0 },
      }],
    });
    await assert.rejects(
      store.replaceElements({
        pageID,
        expectedRevision: `0@${appActor}`,
        transform: () => [],
      }),
      ConflictError,
    );
  });
});

test("keeps every agent layer inside the physical page", async () => {
  await withStore(async (store) => {
    await assert.rejects(
      store.replaceElements({
        pageID,
        expectedRevision: `0@${appActor}`,
        transform: () => [{
          id: "outside",
          kind: "markdown",
          frame: { x: 800, y: 0, width: 100, height: 100 },
          source: "x",
          html: "x",
          css: "",
          javaScript: "",
          state: {},
        }],
      }),
      StoreError,
    );
  });
});
