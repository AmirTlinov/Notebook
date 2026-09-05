import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import type {
  BoardDocument,
  WorkspaceIndex,
} from "../src/domain.js";
import { boardHierarchyRevision, revision } from "../src/domain.js";
import {
  StoreError,
  NotebookStore,
  migrateLegacyStore,
} from "../src/store.js";
import { appActor, itemID, pageID, rootBoardID, writeFixture } from "./fixture.js";

async function withStore(
  body: (store: NotebookStore, root: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "notebook-mcp-"));
  try {
    await writeFixture(root);
    await body(new NotebookStore(root), root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("reads the page selected by the native workspace", async () => {
  await withStore(async (store) => {
    const page = await store.readCurrentPage();
    assert.equal(page.id, pageID);
    assert.equal(revision(page.agentStamp), `0@${appActor}`);
  });
});

test("moves the legacy local store to Notebook once", async () => {
  const parent = await mkdtemp(join(tmpdir(), "notebook-migration-"));
  const legacyRoot = join(parent, "Tetrad");
  const currentRoot = join(parent, "Notebook");
  try {
    await writeFixture(legacyRoot);

    migrateLegacyStore(legacyRoot, currentRoot);

    assert.equal(await readFile(join(currentRoot, "workspace.json"), "utf8") !== "", true);
    await assert.rejects(readFile(join(legacyRoot, "workspace.json"), "utf8"));
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test("reads one-owner board, spatial ink, and current presence", async () => {
  await withStore(async (store) => {
    const workspace = await store.readWorkspace();
    const [board, ink, presence] = await Promise.all([
      store.readBoard(workspace),
      store.readSpatialInk(),
      store.readPresence(),
    ]);
    assert.equal(board.freeItems[0]?.itemID, itemID);
    assert.equal(ink.actions.length, 0);
    assert.equal(presence.mode, "page");
  });
});

test("requires the typed surface revision for the settled view", async () => {
  await withStore(async (store, root) => {
    const receiptPath = join(root, "previews", "current-view.revision");
    const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as Record<string, unknown>;
    delete receipt.surface;
    await writeFile(receiptPath, JSON.stringify(receipt));

    await assert.rejects(store.readCurrentViewReceipt(), StoreError);
  });
});

test("reads legacy notebook and board files through their current owners", async () => {
  await withStore(async (store, root) => {
    const [workspace, board, presence] = await Promise.all([
      store.readWorkspace(),
      store.readBoard(),
      store.readPresence(),
    ]);
    await Promise.all([
      writeFile(join(root, "workspace.json"), JSON.stringify({
        format: 1,
        notebooks: workspace.items.map(({ kind: _kind, ...item }) => item),
        selectedNotebookID: workspace.selectedItemID,
        selectedPageID: workspace.selectedPageID,
        stamp: workspace.stamp,
      })),
      writeFile(join(root, "board.json"), JSON.stringify({
        format: 1,
        freeNotebooks: board.freeItems.map((placement) => ({
          notebookID: placement.itemID,
          center: placement.center,
          zIndex: placement.zIndex,
          stamp: placement.stamp,
        })),
        stacks: board.stacks.map((stack) => ({
          id: stack.id,
          center: stack.center,
          zIndex: stack.zIndex,
          notebookIDs: stack.itemIDs,
          stamp: stack.stamp,
        })),
        elements: board.elements,
        stamp: board.stamp,
      })),
      writeFile(join(root, "last-context.json"), JSON.stringify({
        format: 1,
        mode: presence.mode,
        camera: presence.camera,
        viewport: presence.viewport,
        focusedNotebookID: presence.focusedItemID,
        openProgress: presence.openProgress,
      })),
    ]);

    const migratedWorkspace = await store.readWorkspace();
    const migratedBoard = await store.readBoard(migratedWorkspace);
    const migratedPresence = await store.readPresence();
    assert.equal(migratedWorkspace.format, 3);
    assert.equal(migratedWorkspace.items[0]?.kind, "notebook");
    assert.equal(migratedBoard.format, 2);
    assert.equal(migratedBoard.freeItems[0]?.itemID, itemID);
    assert.equal(migratedPresence.format, 4);
    assert.equal(migratedPresence.boardID, migratedWorkspace.rootBoardID);
    assert.equal(migratedPresence.focusedItemID, itemID);
    assert.equal(migratedPresence.documentPageIndex, 0);
  });
});

test("migrates version-two presence to the first document page", async () => {
  await withStore(async (store, root) => {
    const presence = await store.readPresence();
    await writeFile(join(root, "last-context.json"), JSON.stringify({
      format: 2,
      mode: presence.mode,
      camera: presence.camera,
      viewport: presence.viewport,
      focusedItemID: presence.focusedItemID,
      openProgress: presence.openProgress,
    }));

    const migrated = await store.readPresence();

    assert.equal(migrated.format, 4);
    assert.equal(migrated.boardID, "7e7a0000-0000-4000-8000-000000000003");
    assert.equal(migrated.documentPageIndex, 0);
  });
});

test("waits for the catalog when a board placement arrives first", async () => {
  await withStore(async (store, root) => {
    const boardPath = join(root, "board.json");
    const board = JSON.parse(await readFile(boardPath, "utf8")) as {
      boards: Array<{ board: { freeItems: Array<Record<string, unknown>> } }>;
    };
    board.boards[0]!.board.freeItems.push({
      itemID: "7e7a0000-0000-4000-8000-000000000099",
      center: { tileX: 0, tileY: 0, localX: 900, localY: 0 },
      zIndex: 1,
      stamp: { counter: 1, actor: appActor },
    });
    await writeFile(boardPath, JSON.stringify(board));

    await assert.rejects(store.readBoard(await store.readWorkspace()), StoreError);
  });
});

test("rejects a stack that cannot expose every notebook", async () => {
  await withStore(async (store, root) => {
    const workspacePath = join(root, "workspace.json");
    const boardPath = join(root, "board.json");
    const workspace = JSON.parse(
      await readFile(workspacePath, "utf8"),
    ) as WorkspaceIndex;
    const board = JSON.parse(
      await readFile(boardPath, "utf8"),
    ) as BoardDocument;
    const additionalNotebookIDs = [
      "7e7a0000-0000-4000-8000-000000000011",
      "7e7a0000-0000-4000-8000-000000000012",
      "7e7a0000-0000-4000-8000-000000000013",
      "7e7a0000-0000-4000-8000-000000000014",
      "7e7a0000-0000-4000-8000-000000000015",
    ];
    workspace.items.push(...additionalNotebookIDs.map((id, index) => ({
      id,
      kind: "notebook" as const,
      title: `Notebook ${index + 2}`,
      pageIDs: [`7e7a0000-0000-4000-8000-00000000002${index + 1}`],
    })));
    board.freeItems = [];
    board.stacks = [{
      id: "7e7a0000-0000-4000-8000-000000000030",
      center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
      zIndex: 1,
      itemIDs: [itemID, ...additionalNotebookIDs],
      stamp: { counter: 1, actor: appActor },
    }];
    await Promise.all([
      writeFile(workspacePath, JSON.stringify(workspace)),
      writeFile(boardPath, JSON.stringify(board)),
    ]);

    await assert.rejects(
      store.readBoard(await store.readWorkspace()),
      StoreError,
    );
  });
});

test("rejects a workspace whose selection has no live page", async () => {
  await withStore(async (store, root) => {
    const path = join(root, "workspace.json");
    const workspace = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>;
    workspace.items = [];
    await writeFile(path, JSON.stringify(workspace));

    await assert.rejects(store.readWorkspace(), StoreError);
  });
});

test("rejects a page with an impossible physical size", async () => {
  await withStore(async (store, root) => {
    const path = join(root, "pages", `${pageID}.json`);
    const page = JSON.parse(await readFile(path, "utf8")) as {
      size: { width: number; height: number };
    };
    page.size.width = 0;
    await writeFile(path, JSON.stringify(page));

    await assert.rejects(store.readPage(pageID), StoreError);
  });
});

test("rejects a page size that could exhaust the native renderer", async () => {
  await withStore(async (store, root) => {
    const path = join(root, "pages", `${pageID}.json`);
    const page = JSON.parse(await readFile(path, "utf8")) as {
      size: { width: number; height: number };
    };
    page.size.width = 1e100;
    await writeFile(path, JSON.stringify(page));

    await assert.rejects(store.readPage(pageID), StoreError);
  });
});

test("rejects a revision that JavaScript cannot represent exactly", async () => {
  await withStore(async (store, root) => {
    const path = join(root, "pages", `${pageID}.json`);
    const page = JSON.parse(await readFile(path, "utf8")) as {
      agentStamp: { counter: number };
    };
    page.agentStamp.counter = Number.MAX_SAFE_INTEGER + 1;
    await writeFile(path, JSON.stringify(page));

    await assert.rejects(store.readPage(pageID), StoreError);
  });
});

test("rejects a non-finite number inside interactive state", async () => {
  await withStore(async (store, root) => {
    const path = join(root, "pages", `${pageID}.json`);
    const page = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>;
    const encoded = JSON.stringify({
      ...page,
      elements: [{
        id: "counter",
        kind: "web",
        frame: { x: 0, y: 0, width: 100, height: 100 },
        source: "",
        html: "",
        css: "",
        javaScript: "",
        state: "NON_FINITE_NUMBER",
      }],
    }).replace('"NON_FINITE_NUMBER"', "1e400");
    await writeFile(path, encoded);

    await assert.rejects(store.readPage(pageID), StoreError);
  });
});


test("tree identity matches the Swift frontier and includes every portal", async () => {
  await withStore(async (store) => {
    const tree = await store.readBoardHierarchy();
    assert.equal(boardHierarchyRevision(tree), "480b5648900dd575275f5bb02828bc85d5d49a3ced16ad2f16d3ef6158103eb5");
    const old = boardHierarchyRevision(tree);
    tree.stamp = { counter: 20, actor: appActor };
    assert.equal(boardHierarchyRevision(tree), old);
    tree.boards[0]!.portalStamp = { counter: 1, actor: appActor };
    assert.notEqual(boardHierarchyRevision(tree), old);
  });
});

test("legacy root ink gains its permanent board owner while retaining every action", async () => {
  await withStore(async (store, root) => {
    const stamp = { counter: 1, actor: appActor };
    const point = { point: { x: 0, y: 0 }, worldPoint: { tileX: 0, tileY: 0, localX: 15, localY: 20 },
      timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1 };
    const legacy = { format: 1, stamp, actions: [{
      id: itemID, tool: "pen", color: { red: 0, green: 0, blue: 0 }, stamp, stateStamp: stamp, isActive: true,
      spans: [{ surface: { kind: "board" }, samples: [point] }, {
        surface: { kind: "cover", ownerID: itemID },
        samples: [{ ...point, worldPoint: undefined }],
      }],
    }] };
    await writeFile(join(root, "spatial-ink.json"), JSON.stringify(legacy));
    const resolved = await store.readSpatialInk();
    const expected = JSON.parse(JSON.stringify(legacy));
    expected.actions[0].spans[0].surface.ownerID = rootBoardID;
    assert.deepEqual(resolved, expected);
    assert.deepEqual(JSON.parse(await readFile(join(root, "spatial-ink.json"), "utf8")), JSON.parse(JSON.stringify(legacy)));
    expected.actions[0].spans[0].surface.ownerID = 42;
    await writeFile(join(root, "spatial-ink.json"), JSON.stringify(expected));
    await assert.rejects(store.readSpatialInk(), StoreError);
  });
});
