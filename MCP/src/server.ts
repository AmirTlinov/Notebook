import { registerActionTools } from "./actions.js";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

import type {
  BoardDocument,
  CurrentViewReceipt,
  DocumentBlock,
  DocumentDocument,
  DocumentStateJournal,
  JSONValue,
  PageDocument,
  PageSize,
  SessionPresence,
  SpatialElement,
  VersionStamp,
  WorldPoint,
  WorkspaceIndex,
  WorkspaceItem,
} from "./domain.js";
import {
  boardHierarchyRevision,
  publicDocument,
  publicPage,
  revision,
} from "./domain.js";
import {
  StoreError,
  NotebookStore,
} from "./store.js";
import { exportDocument } from "./latex.js";
import {
  readFreshPageVision,
  readVerifiedPageOverview,
  registerPageVisionTools,
} from "./page-vision.js";

const TILE_SIZE = (132 / 2.54 / 2) * 256;

const pageSelection = {
  page_id: z.uuid().optional().describe("UUID страницы; по умолчанию текущая страница."),
  notebook_id: z.uuid().optional().describe("UUID тетради для выбора по номеру."),
  page_number: z.number().int().positive().optional().describe("Номер листа от 1."),
};

const documentSelection = {
  document_id: z.uuid().optional().describe(
    "UUID документа; по умолчанию текущий открытый документ.",
  ),
};

export function createServer(store = new NotebookStore()): McpServer {
  const server = new McpServer({ name: "notebook", version: "0.2.0" });
  const readSafely = (operation: () => Promise<ToolData | { data: ToolData; image: string }>, hasImage = false) =>
    safely(() => store.withReadSnapshot(operation), hasImage);

  server.registerTool(
    "notebook_observe",
    {
      title: "Observe Amir's settled Notebook view",
      description:
        "Wait briefly for publication, then return one verified settled image with its selected item, compact Pencil map, and joined board nodes. Call this first.",
      inputSchema: z.object({}),
    },
    () => safely(() => waitForSettledSnapshot(async () => {
      const current = await store.readCurrent();
      const { workspace, presence, item } = current;
      const [hierarchy, spatialInk, receipt, itemSizes] = await Promise.all([
        store.readBoardHierarchy(workspace),
        store.readSpatialInk(),
        store.readCurrentViewReceipt(),
        store.readItemSizes(workspace),
      ]);
      const board = hierarchy.boards.find((node) => sameID(node.id, presence.boardID))?.board;
      if (!board) throw new StoreError("Текущая доска ожидает публикации.");
      assertFreshCurrentView(
        receipt,
        workspace.stamp,
        boardHierarchyRevision(hierarchy),
        spatialInk.stamp,
        presence,
      );
      await assertCurrentSurfaceSource(store, receipt);
      const png = await readCurrentViewPNG(store, receipt);
      const itemIndex = workspace.items.findIndex(
        (candidate) => sameID(candidate.id, item.id),
      );
      const focusedStackID = presence.focusedItemID
        ? board.stacks.find((stack) => stack.itemIDs.some(
          (itemID) => sameID(itemID, presence.focusedItemID!),
        ))?.id ?? null
        : null;
      const content = current.kind === "notebook"
        ? await observedPage(store, current.page, item)
        : current.kind === "document"
          ? observedDocument(current.document, current.state)
          : {
              kind: "board",
              boardID: presence.boardID,
              itemCount: board.freeItems.length
                + board.stacks.reduce(
                  (count, stack) => count + stack.itemIDs.length,
                  0,
                ),
            };
      return {
        data: {
          status: "ready",
          mode: presence.mode,
          boardID: presence.boardID,
          camera: presence.camera,
          viewport: presence.viewport,
          focusedItemID: presence.focusedItemID ?? null,
          focusedStackID,
          openProgress: presence.openProgress,
          documentPageIndex: presence.documentPageIndex,
          item: {
            id: item.id,
            kind: item.kind,
            title: item.title || null,
            identity: itemIdentity(item, board, spatialInk),
            number: itemIndex + 1,
            count: workspace.items.length,
          },
          content,
          revisions: {
            workspace: revision(workspace.stamp),
            board: revision(board.stamp),
            spatialInk: revision(spatialInk.stamp),
          },
          nodes: joinedBoardNodes(workspace, board, spatialInk, itemSizes),
          visibleItems: visibleItems(workspace, board, spatialInk, presence, itemSizes),
          appliedPencilActionCount: spatialInk.actions.filter(
            (action) => action.isActive,
          ).length,
          surface: receipt.surface,
          pixelEncoding: "image/png",
        },
        image: png.toString("base64"),
      };
    }), true),
  );

  server.registerTool(
    "notebook_read_board",
    {
      title: "Read the infinite Notebook board",
      description:
        "Read every free notebook or document, stack, and agent-authored board or cover element. "
        + "Use notebook_observe for the settled visual context.",
      inputSchema: z.object({ board_id: z.uuid().optional() }),
    },
    ({ board_id }) => readSafely(async () => {
      const workspace = await store.readWorkspace();
      const boardID = board_id ?? (await store.readPresence()).boardID;
      const [board, spatialInk, itemSizes] = await Promise.all([
        store.readBoard(workspace, boardID),
        store.readSpatialInk(),
        store.readItemSizes(workspace),
      ]);
      return {
        boardID,
        rootBoardID: workspace.rootBoardID,
        workspaceRevision: revision(workspace.stamp),
        boardRevision: revision(board.stamp),
        spatialInkRevision: revision(spatialInk.stamp),
        nodes: joinedBoardNodes(workspace, board, spatialInk, itemSizes),
        elements: board.elements.map(publicSpatialElement),
        appliedPencilActionCount: spatialInk.actions.filter(
          (action) => action.isActive,
        ).length,
      };
    }),
  );

  server.registerTool(
    "notebook_read_notebook",
    {
      title: "Read a notebook and its cover",
      description:
        "Read notebook pages, placement or stack ownership, and all agent-authored cover elements.",
      inputSchema: z.object({ notebook_id: z.uuid() }),
    },
    ({ notebook_id }) => readSafely(async () => {
      const workspace = await store.readWorkspace();
      const [board, spatialInk] = await Promise.all([
        store.readItemBoard(notebook_id, workspace),
        store.readSpatialInk(),
      ]);
      const notebook = workspace.items.find((candidate) =>
        candidate.kind === "notebook" && sameID(candidate.id, notebook_id)
      );
      if (!notebook) throw new StoreError("Тетрадь не найдена.");
      const placement = board.freeItems.find(
        (candidate) => sameID(candidate.itemID, notebook.id),
      );
      const stack = board.stacks.find(
        (candidate) => candidate.itemIDs.some((id) => sameID(id, notebook.id)),
      );
      const pages = await Promise.all(notebook.pageIDs.map(async (pageID, index) => {
        const page = await store.readPage(pageID);
        return {
          number: index + 1,
          id: page.id,
          size: page.size,
          drawingRevision: revision(page.drawingStamp),
          agentRevision: revision(page.agentStamp),
          agentElementCount: page.elements.length,
        };
      }));
      return {
        notebook: {
          id: notebook.id,
          title: notebook.title || null,
          pageCount: notebook.pageIDs.length,
        },
        identity: itemIdentity(notebook, board, spatialInk),
        selectedPageID: sameID(workspace.selectedItemID, notebook.id)
          ? workspace.selectedPageID
          : null,
        placement: placement ?? null,
        stack: stack ?? null,
        pages,
        coverElements: board.elements.filter(
          (element) => element.surface.kind === "cover"
            && sameID(element.surface.ownerID!, notebook.id),
        ).map(publicSpatialElement),
        appliedCoverPencilActionCount: spatialInk.actions.filter(
          (action) => action.isActive && action.spans.some(
            (span) => span.surface.kind === "cover"
              && sameID(span.surface.ownerID!, notebook.id),
          ),
        ).length,
        workspaceRevision: revision(workspace.stamp),
        boardRevision: revision(board.stamp),
      };
    }),
  );

  server.registerTool(
    "notebook_read_document",
    {
      title: "Read a document",
      description:
        "Return a compact ordered outline by default. Set block_id for one complete block or include_source for the full document.",
      inputSchema: z.object({
        ...documentSelection,
        block_id: z.string().trim().min(1).max(120).optional(),
        include_source: z.boolean().default(false),
      }),
    },
    ({ document_id, block_id, include_source }) => readSafely(async () => {
      const documentID = await resolveDocumentID(store, document_id);
      const [document, state] = await Promise.all([
        store.readDocument(documentID),
        store.readDocumentState(documentID),
      ]);
      if (block_id) {
        const block = document.blocks.find((candidate) => candidate.id === block_id);
        if (!block) throw new StoreError(`Блок не найден: ${block_id}`);
        const value = state.records.find((record) => record.id === block.id)?.value;
        return {
          documentID: document.id,
          contentRevision: revision(document.contentStamp),
          stateRevision: revision(state.stamp),
          block: publicDocumentBlock(block, value),
        };
      }
      return include_source
        ? publicDocument(document, state)
        : observedDocument(document, state);
    }),
  );

  server.registerTool(
    "notebook_export_document",
    {
      title: "Compile a document to PDF",
      description:
        "Compile the complete LaTeX artifact locally with Tectonic, then publish its .tex and .pdf files under Notebook/exports.",
      inputSchema: z.object(documentSelection),
    },
    ({ document_id }) => readSafely(async () => {
      const documentID = await resolveDocumentID(store, document_id);
      const document = await store.readDocument(documentID);
      const receipt = await exportDocument(document, join(store.root, "exports"));
      return {
        ...receipt,
        contentRevision: revision(document.contentStamp),
      };
    }),
  );

  server.registerTool(
    "notebook_read_page",
    {
      title: "Read a Notebook page",
      description:
        "Read page size and all agent-authored Markdown, SVG, CSS, JavaScript, and interactive state. " +
        "Call notebook_render_page to see Pencil handwriting.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id, notebook_id, page_number }) => readSafely(async () => {
      const page = await resolvePageSelection(
        store,
        page_id,
        notebook_id,
        page_number,
      );
      return publicPage(page);
    }),
  );

  server.registerTool(
    "notebook_render_page",
    {
      title: "See Pencil handwriting",
      description:
        "Return a PNG of the faint grid and Apple Pencil drawing. " +
        "Use notebook_page_map and notebook_render_region for small handwriting. " +
        "Agent-authored web layers are returned as source by notebook_read_page.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id, notebook_id, page_number }) => readSafely(async () => {
      const page = await resolvePageSelection(
        store,
        page_id,
        notebook_id,
        page_number,
      );
      const receipt = await readFreshPageVision(store, page);
      const png = await readVerifiedPageOverview(store, receipt, "faithful");
      return {
        data: {
          pageID: page.id,
          drawingRevision: revision(receipt.drawingStamp),
          pngSHA256: receipt.previewPNG_SHA256,
          pixelEncoding: "image/png",
        },
        image: png.toString("base64"),
      };
    }, true),
  );

  registerActionTools(server, store);
  registerPageVisionTools(server, store);
  return server;
}

function visibleItems(
  workspace: WorkspaceIndex,
  board: BoardDocument,
  spatialInk: Awaited<ReturnType<NotebookStore["readSpatialInk"]>>,
  presence: SessionPresence,
  itemSizes: Map<string, PageSize>,
): object[] {
  const byID = new Map(
    workspace.items.map((item) => [item.id.toLowerCase(), item]),
  );
  const rendered: Array<{
    itemID: string;
    title: string;
    center: WorldPoint;
    zIndex: number;
    stackID: string | null;
  }> = [];
  for (const placement of board.freeItems) {
    const item = byID.get(placement.itemID.toLowerCase());
    if (!item) continue;
    rendered.push({
      itemID: item.id,
      title: item.title,
      center: placement.center,
      zIndex: placement.zIndex,
      stackID: null,
    });
  }
  for (const stack of board.stacks) {
    const projectedHeight = 1_194 * presence.camera.scale;
    const fitScale = Math.min(
      presence.viewport.x / 834,
      presence.viewport.y / 1_194,
    );
    const coverProjectedHeight = 1_194 * fitScale * 0.72;
    const fanEnd = Math.min(600, coverProjectedHeight);
    const fanStart = Math.min(160, fanEnd * 0.75);
    const fan = clamp(
      (projectedHeight - fanStart) / (fanEnd - fanStart),
      0,
      1,
    );
    const focusedMemberID = presence.mode === "board"
      ? undefined
      : stack.itemIDs.find((itemID) =>
        presence.focusedItemID
          ? sameID(itemID, presence.focusedItemID)
          : false
      );
    const spanCount = Math.max(stack.itemIDs.length - 1, 1);
    for (const [index, itemID] of stack.itemIDs.entries()) {
      if (focusedMemberID && !sameID(focusedMemberID, itemID)) continue;
      const item = byID.get(itemID.toLowerCase());
      if (!item) continue;
      const centered = index - (stack.itemIDs.length - 1) / 2;
      const collapsedX = centered * 9 / Math.max(presence.camera.scale, 0.001);
      const collapsedY = -index * 7 / Math.max(presence.camera.scale, 0.001);
      const fannedX = centered * 834 * 0.62 / spanCount;
      const fannedY = Math.abs(centered) * 1_194 * 0.08 / spanCount;
      rendered.push({
        itemID: item.id,
        title: item.title,
        center: offsetWorld(
          stack.center,
          collapsedX + (fannedX - collapsedX) * fan,
          collapsedY + (fannedY - collapsedY) * fan,
        ),
        zIndex: stack.zIndex + index / 100,
        stackID: stack.id,
      });
    }
  }
  return rendered
    .sort((first, second) => first.zIndex - second.zIndex)
    .map((item) => {
      const center = worldToScreen(item.center, presence);
      const size = itemSizes.get(item.itemID.toLowerCase())!;
      const width = size.width * presence.camera.scale;
      const height = size.height * presence.camera.scale;
      return {
        ...item,
        identity: itemIdentity(
          byID.get(item.itemID.toLowerCase())!,
          board,
          spatialInk,
        ),
        coverSize: size,
        screenFrame: {
          x: center.x - width / 2,
          y: center.y - height / 2,
          width,
          height,
        },
      };
    })
    .filter((item) => item.screenFrame.x < presence.viewport.x
      && item.screenFrame.y < presence.viewport.y
      && item.screenFrame.x + item.screenFrame.width > 0
      && item.screenFrame.y + item.screenFrame.height > 0)
    .slice(-200);
}

function itemIdentity(
  item: WorkspaceIndex["items"][number],
  board: BoardDocument,
  spatialInk: Awaited<ReturnType<NotebookStore["readSpatialInk"]>>,
): object {
  const title = item.title.trim();
  const shortID = item.id.slice(0, 8).toUpperCase();
  const coverElements = board.elements.filter((element) =>
    element.surface.kind === "cover"
      && sameID(element.surface.ownerID!, item.id)
  );
  const coverPencilActionCount = spatialInk.actions.filter(
    (action) => action.isActive && action.spans.some(
      (span) => span.surface.kind === "cover"
        && sameID(span.surface.ownerID!, item.id),
    ),
  ).length;
  return {
    itemID: item.id,
    kind: item.kind,
    shortID,
    title: title || null,
    reference: title || `Безымянная #${shortID}`,
    coverPencilActionCount,
    coverElementIDs: coverElements.map((element) => element.id),
  };
}

function publicSpatialElement(element: SpatialElement): object {
  return {
    id: element.id,
    surface: element.surface.kind === "cover"
      ? { kind: "cover", item_id: element.surface.ownerID }
      : { kind: "board", board_id: element.surface.ownerID },
    kind: element.kind,
    frame: element.frame,
    world_origin: element.worldOrigin ?? null,
    source: element.source,
    html: element.html,
    css: element.css,
    javascript: element.javaScript,
    state: element.state,
    text_style: element.textStyle,
    revision: revision(element.stamp),
  };
}

async function observedPage(
  store: NotebookStore,
  page: PageDocument,
  item: WorkspaceItem,
): Promise<object> {
  const vision = await readFreshPageVision(store, page);
  const occupied = vision.occupiedCells;
  const columns = occupied.map((cell) => cell.column);
  const rows = occupied.map((cell) => cell.row);
  return {
    kind: "page",
    selector: {
      itemID: item.id,
      pageID: page.id,
      pageNumber: item.pageIDs.findIndex((id) => sameID(id, page.id)) + 1,
      pageCount: item.pageIDs.length,
    },
    size: page.size,
    drawingRevision: revision(page.drawingStamp),
    agentRevision: revision(page.agentStamp),
    agentElements: page.elements.map((element) => ({
      id: element.id,
      kind: element.kind,
      frame: element.frame,
    })),
    pencilMap: {
      blank: vision.regions.length === 0,
      occupiedCellCount: occupied.length,
      occupiedCellBounds: occupied.length === 0
        ? null
        : {
            column: Math.min(...columns),
            row: Math.min(...rows),
            width: Math.max(...columns) - Math.min(...columns) + 1,
            height: Math.max(...rows) - Math.min(...rows) + 1,
          },
      visibleInkBounds: vision.visibleInkBounds ?? null,
      regions: vision.regions.map((region) => ({
        id: region.id,
        contentCells: region.contentCells,
        inkPixelCount: region.inkPixelCount,
      })),
    },
  };
}

function observedDocument(
  document: DocumentDocument,
  state: DocumentStateJournal,
): object {
  const stateByID = new Map(state.records.map((record) => [record.id, record.value]));
  return {
    kind: "document",
    id: document.id,
    paperSize: document.paperSize,
    contentRevision: revision(document.contentStamp),
    stateRevision: revision(state.stamp),
    preambleCharacterCount: document.preamble.length,
    blocks: document.blocks.map((block) => ({
      id: block.id,
      kind: block.kind,
      sourcePreview: block.kind === "interactive"
        ? textPreview(block.html)
        : textPreview(block.source),
      sourceCharacterCount: block.kind === "interactive"
        ? block.html.length
        : block.source.length,
      height: block.kind === "interactive" ? block.height : null,
      hasCSS: block.kind === "interactive" && block.css.length > 0,
      hasJavaScript: block.kind === "interactive" && block.javaScript.length > 0,
      state: block.kind === "interactive"
        ? stateByID.get(block.id) ?? block.initialState
        : null,
    })),
  };
}

function publicDocumentBlock(
  block: DocumentBlock,
  state: JSONValue | undefined,
): object {
  if (block.kind === "interactive") {
    return {
      id: block.id,
      kind: block.kind,
      html: block.html,
      css: block.css,
      javascript: block.javaScript,
      initial_state: block.initialState,
      state: state ?? block.initialState,
      height: block.height,
    };
  }
  return {
    id: block.id,
    kind: block.kind,
    source: block.source,
  };
}

function textPreview(value: string): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  return normalized.length <= 160 ? normalized : `${normalized.slice(0, 157)}...`;
}

function joinedBoardNodes(
  workspace: WorkspaceIndex,
  board: BoardDocument,
  spatialInk: Awaited<ReturnType<NotebookStore["readSpatialInk"]>>,
  itemSizes: Map<string, PageSize>,
): object[] {
  const items = new Map(
    workspace.items.map((item) => [item.id.toLowerCase(), item]),
  );
  const free = board.freeItems.map((placement) => {
    const item = items.get(placement.itemID.toLowerCase())!;
    return {
      kind: "item",
      id: item.id,
      identity: itemIdentity(item, board, spatialInk),
      coverSize: itemSizes.get(item.id.toLowerCase()),
      center: placement.center,
      zIndex: placement.zIndex,
      stackID: null,
    };
  });
  const stacks = board.stacks.map((stack) => ({
    kind: "stack",
    id: stack.id,
    center: stack.center,
    zIndex: stack.zIndex,
    items: stack.itemIDs.map((itemID) => {
      const item = items.get(itemID.toLowerCase())!;
      return { ...itemIdentity(item, board, spatialInk), coverSize: itemSizes.get(item.id.toLowerCase()) };
    }),
  }));
  return [...free, ...stacks].sort((first, second) =>
    (first.zIndex as number) - (second.zIndex as number)
  );
}

async function assertCurrentSurfaceSource(
  store: NotebookStore,
  receipt: CurrentViewReceipt,
): Promise<void> {
  if (receipt.surface.kind === "page") {
    const surface = receipt.surface;
    const [page, workspace] = await Promise.all([
      store.readPage(surface.revision.pageID),
      store.readWorkspace(),
    ]);
    const owner = workspace.items.find((item) =>
      item.kind === "notebook"
        && sameID(item.id, surface.itemID)
        && item.pageIDs.some((pageID) =>
          sameID(pageID, surface.revision.pageID)
        )
    );
    if (!owner) {
      throw new StoreError("Квитанция связывает лист с другой тетрадью.");
    }
    if (!sameStamp(page.drawingStamp, surface.revision.drawingStamp)
      || !sameStamp(page.agentStamp, surface.revision.agentStamp)) {
      throw new StoreError(
        "Снимок листа еще собирается в фоне. Повторите notebook_observe через мгновение.",
      );
    }
  }
  if (receipt.surface.kind === "document") {
    const [document, state] = await Promise.all([
      store.readDocument(receipt.surface.revision.documentID),
      store.readDocumentState(receipt.surface.revision.documentID),
    ]);
    if (!sameStamp(document.contentStamp, receipt.surface.revision.contentStamp)
      || !sameStamp(state.stamp, receipt.surface.revision.stateStamp)) {
      throw new StoreError(
        "Снимок документа еще собирается в фоне. Повторите notebook_observe через мгновение.",
      );
    }
  }
}

async function readCurrentViewPNG(
  store: NotebookStore,
  receipt: CurrentViewReceipt,
): Promise<Buffer> {
  let png: Buffer;
  try {
    png = await readFile(store.currentViewPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code === "ENOENT") {
      throw new StoreError(
        "Текущий вид еще создается. Notebook на Mac должен оставаться запущенным.",
      );
    }
    throw error;
  }
  if (createHash("sha256").update(png).digest("hex") !== receipt.pngSHA256) {
    throw new StoreError(
      "Снимок и его квитанция обновляются. Повторите notebook_observe через мгновение.",
    );
  }
  return png;
}

function assertFreshCurrentView(
  receipt: CurrentViewReceipt,
  workspaceStamp: VersionStamp,
  boardRevision: string,
  spatialInkStamp: VersionStamp,
  presence: SessionPresence,
): void {
  if (!sameStamp(receipt.workspaceStamp, workspaceStamp)
    || receipt.boardRevision !== boardRevision
    || !sameStamp(receipt.spatialInkStamp, spatialInkStamp)
    || !isDeepStrictEqual(receipt.presence, presence)) {
    throw new StoreError(
      "Снимок текущего вида еще собирается в фоне. Повторите notebook_observe через мгновение.",
    );
  }
}

async function resolvePageSelection(
  store: NotebookStore,
  pageID: string | undefined,
  notebookID: string | undefined,
  pageNumber: number | undefined,
): Promise<PageDocument> {
  if (pageID && (notebookID || pageNumber)) {
    throw new StoreError("Выберите лист либо по page_id, либо по номеру в тетради.");
  }
  if (pageNumber && !notebookID) {
    throw new StoreError("Для page_number нужен notebook_id.");
  }
  if (pageID) return store.readWorkspacePage(pageID);
  if (!notebookID) return store.readWorkspacePage();

  const workspace = await store.readWorkspace();
  const notebook = workspace.items.find((item) =>
    item.kind === "notebook" && sameID(item.id, notebookID)
  );
  if (!notebook || notebook.kind !== "notebook") {
    throw new StoreError("Тетрадь не найдена.");
  }
  const index = pageNumber === undefined
    ? (sameID(workspace.selectedItemID, notebook.id)
      ? Math.max(0, notebook.pageIDs.findIndex((id) =>
          workspace.selectedPageID !== undefined
            && sameID(id, workspace.selectedPageID)
        ))
      : 0)
    : pageNumber - 1;
  const selectedID = notebook.pageIDs[index];
  if (!selectedID) {
    throw new StoreError(
      `У тетради ${notebook.pageIDs.length} листов; листа ${pageNumber} нет.`,
    );
  }
  return store.readPage(selectedID);
}

async function resolveDocumentID(
  store: NotebookStore,
  requestedID: string | undefined,
): Promise<string> {
  if (requestedID) {
    const workspace = await store.readWorkspace();
    const item = workspace.items.find((candidate) =>
      sameID(candidate.id, requestedID)
    );
    if (!item || item.kind !== "document") {
      throw new StoreError("Документ не найден.");
    }
    return item.id;
  }
  const current = await store.readCurrent();
  if (current.kind !== "document") {
    throw new StoreError("Сейчас открыт лист тетради, а не документ.");
  }
  return current.document.id;
}

function worldToScreen(
  point: WorldPoint,
  presence: SessionPresence,
): { x: number; y: number } {
  const deltaX = (point.tileX - presence.camera.center.tileX) * TILE_SIZE
    + point.localX - presence.camera.center.localX;
  const deltaY = (point.tileY - presence.camera.center.tileY) * TILE_SIZE
    + point.localY - presence.camera.center.localY;
  return {
    x: presence.viewport.x / 2 + deltaX * presence.camera.scale,
    y: presence.viewport.y / 2 + deltaY * presence.camera.scale,
  };
}

function offsetWorld(point: WorldPoint, x: number, y: number): WorldPoint {
  const rawX = point.localX + x;
  const rawY = point.localY + y;
  const tileOffsetX = Math.floor(rawX / TILE_SIZE);
  const tileOffsetY = Math.floor(rawY / TILE_SIZE);
  return {
    tileX: point.tileX + tileOffsetX,
    tileY: point.tileY + tileOffsetY,
    localX: rawX - tileOffsetX * TILE_SIZE,
    localY: rawY - tileOffsetY * TILE_SIZE,
  };
}

function sameStamp(first: VersionStamp, second: VersionStamp): boolean {
  return first.counter === second.counter && sameID(first.actor, second.actor);
}

function sameID(first: string, second: string): boolean {
  return first.toLowerCase() === second.toLowerCase();
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

const snapshotPendingPattern =
  /собирается|создается|обновляются|обновляется/;

export async function waitForSettledSnapshot<T>(
  operation: () => Promise<T>,
  options: {
    timeoutMilliseconds?: number;
    pollMilliseconds?: number;
  } = {},
): Promise<T> {
  const timeoutMilliseconds = options.timeoutMilliseconds ?? 4_000;
  const pollMilliseconds = options.pollMilliseconds ?? 100;
  const deadline = Date.now() + timeoutMilliseconds;
  while (true) {
    try {
      return await operation();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const remaining = deadline - Date.now();
      if (!snapshotPendingPattern.test(message) || remaining <= 0) throw error;
      await new Promise((resolve) => {
        setTimeout(resolve, Math.min(pollMilliseconds, remaining));
      });
    }
  }
}

type ToolData = object;

async function safely(
  operation: () => Promise<ToolData | { data: ToolData; image: string }>,
  hasImage = false,
): Promise<{
  content: Array<
    | { type: "text"; text: string }
    | { type: "image"; data: string; mimeType: "image/png" }
  >;
  structuredContent?: object;
  isError?: boolean;
}> {
  try {
    const result = await operation();
    if (hasImage && "image" in result && "data" in result) {
      return {
        content: [
          { type: "text", text: JSON.stringify(result.data, null, 2) },
          { type: "image", data: result.image, mimeType: "image/png" },
        ],
        structuredContent: result.data,
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      structuredContent: result,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const pending = snapshotPendingPattern.test(message);
    const data = {
      status: pending ? "pending" : "error",
      code: pending ? "snapshot_pending" : "operation_failed",
      message,
      retryAfterMilliseconds: pending ? 500 : null,
    };
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
      structuredContent: data,
      isError: true,
    };
  }
}
