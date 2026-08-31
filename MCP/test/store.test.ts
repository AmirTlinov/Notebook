import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import type {
  AgentElement,
  BoardDocument,
  WorkspaceIndex,
} from "../src/domain.js";
import { revision } from "../src/domain.js";
import {
  ConflictError,
  StoreError,
  NotebookStore,
  migrateLegacyStore,
  nextVersionStamp,
} from "../src/store.js";
import { appActor, itemID, pageID, writeFixture } from "./fixture.js";

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

test("requires the rendered page revision while the page is open", async () => {
  await withStore(async (store, root) => {
    const receiptPath = join(root, "previews", "current-view.revision");
    const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as Record<string, unknown>;
    delete receipt.page;
    await writeFile(receiptPath, JSON.stringify(receipt));

    await assert.rejects(store.readCurrentViewReceipt(), StoreError);
  });
});

test("moves a board entity under an optimistic board revision", async () => {
  await withStore(async (store) => {
    const moved = await store.replaceBoard({
      expectedRevision: `0@${appActor}`,
      transform: (board, _workspace, actor) => {
        const placement = board.freeItems[0]!;
        placement.center = { tileX: -2, tileY: 3, localX: 40, localY: 70 };
        placement.stamp = nextVersionStamp(board.stamp, actor);
        return board;
      },
    });
    assert.equal(moved.stamp.counter, 1);
    assert.equal(moved.freeItems[0]?.center.tileX, -2);
    await assert.rejects(
      store.replaceBoard({
        expectedRevision: `0@${appActor}`,
        transform: (board) => board,
      }),
      ConflictError,
    );
  });
});

test("creates a notebook, page, and placement as one valid bundle", async () => {
  await withStore(async (store) => {
    const created = await store.createNotebook({
      title: "Исследование",
      center: { tileX: 1, tileY: -1, localX: 100, localY: 200 },
      expectedWorkspaceRevision: `0@${appActor}`,
      expectedBoardRevision: `0@${appActor}`,
    });
    assert.equal(created.workspace.items.length, 2);
    assert.ok(created.board.freeItems.some(
      (placement) => placement.itemID === created.itemID,
    ));
    assert.equal((await store.readPage(created.page.id)).id, created.page.id);
    assert.equal((await store.readBoard(created.workspace)).freeItems.length, 2);
  });
});

test("creates a visually identified notebook without a printed title", async () => {
  await withStore(async (store) => {
    const created = await store.createNotebook({
      title: "",
      center: { tileX: 0, tileY: 0, localX: 400, localY: 500 },
      expectedWorkspaceRevision: `0@${appActor}`,
      expectedBoardRevision: `0@${appActor}`,
    });
    const notebook = created.workspace.items.find(
      (candidate) => candidate.id === created.itemID,
    );
    assert.equal(notebook?.title, "");
    assert.equal((await store.readWorkspace()).items.length, 2);
  });
});

test("creates and patches a document while interactive state keeps its own owner", async () => {
  await withStore(async (store, root) => {
    const created = await store.createDocument({
      title: "Документ",
      center: { tileX: 0, tileY: 0, localX: 400, localY: 500 },
      expectedWorkspaceRevision: `0@${appActor}`,
      expectedBoardRevision: `0@${appActor}`,
      blocks: [{
        id: "body",
        kind: "markdown",
        source: "# Черновик",
        html: "",
        css: "",
        javaScript: "",
        initialState: {},
        height: 320,
      }, {
        id: "counter",
        kind: "interactive",
        source: "<button>0</button>",
        html: "<button>0</button>",
        css: "button { font: inherit }",
        javaScript: "document.querySelector('button').onclick = () => {};",
        initialState: { count: 0 },
        height: 180,
      }],
    });
    assert.equal(created.workspace.selectedItemID, created.itemID);
    assert.equal(created.workspace.selectedPageID, undefined);
    assert.equal(created.document.id, created.itemID);
    assert.equal(created.state.id, created.itemID);
    assert.equal(
      JSON.parse(await readFile(
        join(root, "documents", `${created.itemID}.json`),
        "utf8",
      )).id,
      created.itemID,
    );

    const changed = await store.replaceDocumentContent({
      documentID: created.itemID,
      expectedRevision: revision(created.document.contentStamp),
      preamble: "\\usepackage{microtype}",
      blocks: [{
        ...created.document.blocks[0]!,
        source: "# Чистовой текст",
      }],
    });
    assert.equal(changed.document.contentStamp.counter, 1);
    assert.equal(changed.document.blocks[0]?.source, "# Чистовой текст");
    assert.deepEqual(changed.state, created.state);

    await assert.rejects(
      store.replaceDocumentContent({
        documentID: created.itemID,
        expectedRevision: revision(created.document.contentStamp),
        preamble: "",
        blocks: [],
      }),
      ConflictError,
    );
  });
});

test("creates a canonical notebook when the board currently contains only documents", async () => {
  await withStore(async (store, root) => {
    const createdDocument = await store.createDocument({
      title: "Единственный документ",
      center: { tileX: 0, tileY: 0, localX: 400, localY: 500 },
      expectedWorkspaceRevision: `0@${appActor}`,
      expectedBoardRevision: `0@${appActor}`,
    });
    const documentID = createdDocument.itemID;
    const workspace: WorkspaceIndex = {
      ...createdDocument.workspace,
      items: createdDocument.workspace.items.filter(
        (item) => item.id === documentID,
      ),
      selectedItemID: documentID,
      stamp: {
        counter: createdDocument.workspace.stamp.counter + 1,
        actor: appActor,
      },
    };
    delete workspace.selectedPageID;
    const board: BoardDocument = {
      ...createdDocument.board,
      freeItems: createdDocument.board.freeItems.filter(
        (placement) => placement.itemID === documentID,
      ),
      stamp: {
        counter: createdDocument.board.stamp.counter + 1,
        actor: appActor,
      },
    };
    await Promise.all([
      writeFile(join(root, "workspace.json"), JSON.stringify(workspace)),
      writeFile(join(root, "board.json"), JSON.stringify(board)),
    ]);

    await assert.rejects(store.readWorkspacePage(pageID), StoreError);
    const createdNotebook = await store.createNotebook({
      title: "Возвращённая тетрадь",
      center: { tileX: 0, tileY: 0, localX: 700, localY: 500 },
      expectedWorkspaceRevision: revision(workspace.stamp),
      expectedBoardRevision: revision(board.stamp),
    });

    assert.deepEqual(createdNotebook.page.size, { width: 834, height: 1_194 });
    assert.equal(createdNotebook.workspace.selectedPageID, createdNotebook.page.id);
  });
});

test("reads legacy notebook, board, and presence files through version two owners", async () => {
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
    assert.equal(migratedWorkspace.format, 2);
    assert.equal(migratedWorkspace.items[0]?.kind, "notebook");
    assert.equal(migratedBoard.format, 2);
    assert.equal(migratedBoard.freeItems[0]?.itemID, itemID);
    assert.equal(migratedPresence.format, 2);
    assert.equal(migratedPresence.focusedItemID, itemID);
  });
});

test("accepts a placement staged before the workspace publishes its notebook", async () => {
  await withStore(async (store, root) => {
    const boardPath = join(root, "board.json");
    const board = JSON.parse(await readFile(boardPath, "utf8")) as {
      freeItems: Array<Record<string, unknown>>;
    };
    board.freeItems.push({
      itemID: "7e7a0000-0000-4000-8000-000000000099",
      center: { tileX: 0, tileY: 0, localX: 900, localY: 0 },
      zIndex: 1,
      stamp: { counter: 1, actor: appActor },
    });
    await writeFile(boardPath, JSON.stringify(board));

    assert.equal((await store.readBoard(await store.readWorkspace())).freeItems.length, 2);
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
