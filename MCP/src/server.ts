import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";

import { McpServer } from "@modelcontextprotocol/server";
import { marked } from "marked";
import * as z from "zod/v4";

import type {
  AgentElement,
  BoardDocument,
  CurrentViewReceipt,
  JSONValue,
  PageDocument,
  SessionPresence,
  SpatialElement,
  SurfaceID,
  VersionStamp,
  WorldPoint,
  WorkspaceIndex,
} from "./domain.js";
import { publicPage, revision } from "./domain.js";
import {
  StoreError,
  TetradStore,
  assertFrame,
  assertSpatialFrame,
  boardHighestZIndex,
  nextVersionStamp,
} from "./store.js";

const TILE_SIZE = (132 / 2.54 / 2) * 256;

const frameSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
  width: z.number().positive().finite(),
  height: z.number().positive().finite(),
});

const pageSelection = {
  page_id: z.uuid().optional().describe("UUID страницы; по умолчанию текущая страница."),
};

const worldPointSchema = z.object({
  tileX: z.number().int().safe(),
  tileY: z.number().int().safe(),
  localX: z.number().min(0).lt(TILE_SIZE).finite(),
  localY: z.number().min(0).lt(TILE_SIZE).finite(),
});

const spatialSurfaceSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("board") }),
  z.object({ kind: z.literal("cover"), notebook_id: z.uuid() }),
]);

const spatialSelection = {
  expected_revision: z.string().min(1).describe("boardRevision from tetrad_read_board."),
  surface: spatialSurfaceSchema,
};

export function createServer(store = new TetradStore()): McpServer {
  const server = new McpServer({ name: "tetrad", version: "0.1.0" });

  server.registerTool(
    "tetrad_context",
    {
      title: "Current Tetrad context",
      description:
        "Read the selected notebook and page on this Mac. Call this first to locate the page Amir sees.",
      inputSchema: z.object({}),
    },
    () => safely(async () => {
      const { workspace, page, presence } = await store.readCurrent();
      const [board, spatialInk] = await Promise.all([
        store.readBoard(workspace),
        store.readSpatialInk(),
      ]);
      const notebookIndex = workspace.notebooks.findIndex((notebook) =>
        notebook.pageIDs.some((pageID) => sameID(pageID, page.id))
      );
      const notebook = workspace.notebooks[notebookIndex];
      if (!notebook) throw new StoreError("Выбранная тетрадь не найдена.");
      const pageIndex = notebook.pageIDs.findIndex(
        (pageID) => pageID.toLowerCase() === page.id.toLowerCase(),
      );
      return {
        mode: presence.mode,
        camera: presence.camera,
        viewport: presence.viewport,
        focusedNotebookID: presence.focusedNotebookID ?? null,
        focusedStackID: presence.focusedStackID ?? null,
        openProgress: presence.openProgress,
        notebook: {
          id: notebook.id,
          title: notebook.title,
          number: notebookIndex + 1,
          count: workspace.notebooks.length,
        },
        page: {
          id: page.id,
          number: pageIndex + 1,
          count: notebook.pageIDs.length,
          size: page.size,
          drawingRevision: revision(page.drawingStamp),
          agentRevision: revision(page.agentStamp),
        },
        boardRevision: revision(board.stamp),
        spatialInkRevision: revision(spatialInk.stamp),
        visibleNotebooks: visibleNotebooks(workspace, board, presence),
      };
    }),
  );

  server.registerTool(
    "tetrad_read_board",
    {
      title: "Read the infinite Tetrad board",
      description:
        "Read every free notebook, stack, and agent-authored board or cover element. "
        + "Use tetrad_render_view to see Pencil ink.",
      inputSchema: z.object({}),
    },
    () => safely(async () => {
      const workspace = await store.readWorkspace();
      const [board, spatialInk] = await Promise.all([
        store.readBoard(workspace),
        store.readSpatialInk(),
      ]);
      return {
        boardRevision: revision(board.stamp),
        spatialInkRevision: revision(spatialInk.stamp),
        freeNotebooks: board.freeNotebooks,
        stacks: board.stacks,
        elements: board.elements,
        activePencilActions: spatialInk.actions.filter((action) => action.isActive).length,
      };
    }),
  );

  server.registerTool(
    "tetrad_read_notebook",
    {
      title: "Read a notebook and its cover",
      description:
        "Read notebook pages, placement or stack ownership, and all agent-authored cover elements.",
      inputSchema: z.object({ notebook_id: z.uuid() }),
    },
    ({ notebook_id }) => safely(async () => {
      const workspace = await store.readWorkspace();
      const [board, spatialInk] = await Promise.all([
        store.readBoard(workspace),
        store.readSpatialInk(),
      ]);
      const notebook = workspace.notebooks.find((candidate) => sameID(candidate.id, notebook_id));
      if (!notebook) throw new StoreError("Тетрадь не найдена.");
      const placement = board.freeNotebooks.find(
        (candidate) => sameID(candidate.notebookID, notebook.id),
      );
      const stack = board.stacks.find(
        (candidate) => candidate.notebookIDs.some((id) => sameID(id, notebook.id)),
      );
      return {
        notebook,
        selectedPageID: sameID(workspace.selectedNotebookID, notebook.id)
          ? workspace.selectedPageID
          : null,
        placement: placement ?? null,
        stack: stack ?? null,
        coverElements: board.elements.filter(
          (element) => element.surface.kind === "cover"
            && sameID(element.surface.ownerID!, notebook.id),
        ),
        activeCoverPencilActions: spatialInk.actions.filter(
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
    "tetrad_render_view",
    {
      title: "See what Amir currently sees",
      description:
        "Return a fresh PNG of the current board, cover transition, or page on the Mac mirror.",
      inputSchema: z.object({}),
    },
    () => safely(async () => {
      const [workspace, spatialInk, presence, receipt] = await Promise.all([
        store.readWorkspace(),
        store.readSpatialInk(),
        store.readPresence(),
        store.readCurrentViewReceipt(),
      ]);
      const board = await store.readBoard(workspace);
      assertFreshCurrentView(receipt, workspace.stamp, board.stamp, spatialInk.stamp, presence);
      if (receipt.page) {
        const page = await store.readPage(receipt.page.pageID);
        if (!sameStamp(page.drawingStamp, receipt.page.drawingStamp)
          || !sameStamp(page.agentStamp, receipt.page.agentStamp)) {
          throw new StoreError(
            "Изображение текущего вида догоняет новый лист. Повторите tetrad_render_view через мгновение.",
          );
        }
      }
      let png: Buffer;
      try {
        png = await readFile(store.currentViewPath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === "ENOENT") {
          throw new StoreError(
            "Текущий вид еще не создан. Откройте «Тетрадь» на Mac и оставьте ее запущенной.",
          );
        }
        throw error;
      }
      const pngSHA256 = createHash("sha256").update(png).digest("hex");
      if (pngSHA256 !== receipt.pngSHA256) {
        throw new StoreError(
          "Изображение текущего вида и его квитанция обновляются. Повторите tetrad_render_view через мгновение.",
        );
      }
      return {
        data: {
          mode: presence.mode,
          focusedNotebookID: presence.focusedNotebookID ?? null,
          pageID: receipt.page?.pageID ?? null,
          viewport: receipt.renderViewport,
          workspaceRevision: revision(workspace.stamp),
          boardRevision: revision(board.stamp),
          spatialInkRevision: revision(spatialInk.stamp),
          pixelEncoding: "image/png",
        },
        image: png.toString("base64"),
      };
    }, true),
  );

  server.registerTool(
    "tetrad_create_notebook",
    {
      title: "Create a notebook on the board",
      description:
        "Create a real notebook, its first blank page, and one board placement in one mutation.",
      inputSchema: z.object({
        expected_workspace_revision: z.string().min(1),
        expected_board_revision: z.string().min(1),
        title: z.string().trim().min(1).max(240),
        center: worldPointSchema,
      }),
    },
    ({ expected_workspace_revision, expected_board_revision, title, center }) =>
      safely(async () => {
        const created = await store.createNotebook({
          title,
          center,
          expectedWorkspaceRevision: expected_workspace_revision,
          expectedBoardRevision: expected_board_revision,
        });
        return {
          notebookID: created.notebookID,
          pageID: created.page.id,
          workspaceRevision: revision(created.workspace.stamp),
          boardRevision: revision(created.board.stamp),
        };
      }),
  );

  server.registerTool(
    "tetrad_rename_notebook",
    {
      title: "Rename a notebook",
      description: "Change the title printed on a notebook cover.",
      inputSchema: z.object({
        notebook_id: z.uuid(),
        title: z.string().trim().min(1).max(240),
        expected_workspace_revision: z.string().min(1),
      }),
    },
    ({ notebook_id, title, expected_workspace_revision }) => safely(async () => {
      const workspace = await store.renameNotebook({
        notebookID: notebook_id,
        title,
        expectedRevision: expected_workspace_revision,
      });
      return {
        notebookID: notebook_id,
        title,
        workspaceRevision: revision(workspace.stamp),
      };
    }),
  );

  server.registerTool(
    "tetrad_move_nodes",
    {
      title: "Move notebooks or stacks",
      description:
        "Move board nodes to exact tiled world coordinates. Moving one notebook out of a stack extracts it.",
      inputSchema: z.object({
        expected_revision: z.string().min(1).describe("boardRevision from tetrad_read_board."),
        moves: z.array(z.object({
          kind: z.enum(["notebook", "stack"]),
          id: z.uuid(),
          center: worldPointSchema,
        })).min(1).max(100),
      }),
    },
    ({ expected_revision, moves }) => safely(async () => {
      const duplicate = new Set<string>();
      for (const move of moves) {
        const key = `${move.kind}:${move.id.toLowerCase()}`;
        if (duplicate.has(key)) throw new StoreError(`Узел повторяется в moves: ${move.id}`);
        duplicate.add(key);
      }
      const changed = await store.replaceBoard({
        expectedRevision: expected_revision,
        transform: (board, _workspace, actor) => {
          for (const move of moves) moveNode(board, move.kind, move.id, move.center, actor);
          return board;
        },
      });
      return {
        moved: moves.map(({ kind, id }) => ({ kind, id })),
        boardRevision: revision(changed.stamp),
      };
    }),
  );

  server.registerTool(
    "tetrad_stack_nodes",
    {
      title: "Put one notebook onto another",
      description:
        "Move a free notebook onto a free notebook or an existing stack. The board keeps one owner per notebook.",
      inputSchema: z.object({
        expected_revision: z.string().min(1).describe("boardRevision from tetrad_read_board."),
        moving_notebook_id: z.uuid(),
        target_notebook_id: z.uuid(),
      }),
    },
    ({ expected_revision, moving_notebook_id, target_notebook_id }) => safely(async () => {
      if (sameID(moving_notebook_id, target_notebook_id)) {
        throw new StoreError("Тетрадь нельзя положить на саму себя.");
      }
      let stackID = "";
      const changed = await store.replaceBoard({
        expectedRevision: expected_revision,
        transform: (board, _workspace, actor) => {
          stackID = stackNotebook(
            board,
            moving_notebook_id,
            target_notebook_id,
            actor,
          );
          return board;
        },
      });
      return { stackID, boardRevision: revision(changed.stamp) };
    }),
  );

  server.registerTool(
    "tetrad_put_spatial_markdown",
    {
      title: "Put Markdown on the board or a cover",
      description:
        "Create or replace one transparent Markdown layer. Board layers require a tiled world_origin; cover layers use local 834x1194 coordinates.",
      inputSchema: z.object({
        ...spatialSelection,
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        world_origin: worldPointSchema.optional(),
        markdown: z.string(),
        css: z.string().default(""),
      }),
    },
    ({ expected_revision, surface, id, frame, world_origin, markdown, css }) =>
      safely(async () => {
        const surfaceID = inputSurface(surface);
        assertSpatialPlacement(surfaceID, frame, world_origin);
        const html = await marked.parse(markdown, { async: true, gfm: true });
        const board = await store.replaceBoard({
          expectedRevision: expected_revision,
          transform: (current, workspace, actor) => {
            assertKnownSurface(surfaceID, workspace);
            const stamp = nextVersionStamp(current.stamp, actor);
            const element = spatialElement({
              id,
              surface: surfaceID,
              frame,
              worldOrigin: world_origin,
              kind: "markdown",
              source: markdown,
              html,
              css,
              javaScript: "",
              state: {},
              stamp,
            });
            current.elements = upsertSpatial(current.elements, element);
            return current;
          },
        });
        return spatialMutationReceipt(board, id);
      }),
  );

  server.registerTool(
    "tetrad_put_spatial_web",
    {
      title: "Put an interactive layer on the board or a cover",
      description:
        "Create or replace transparent HTML, SVG, CSS, and JavaScript. Use window.tetrad.commit(value) for state; network access stays blocked.",
      inputSchema: z.object({
        ...spatialSelection,
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        world_origin: worldPointSchema.optional(),
        html: z.string(),
        css: z.string().default(""),
        javascript: z.string().default(""),
        state: z.json().default({}),
      }),
    },
    ({
      expected_revision,
      surface,
      id,
      frame,
      world_origin,
      html,
      css,
      javascript,
      state,
    }) => safely(async () => {
      assertJavaScript(javascript);
      const surfaceID = inputSurface(surface);
      assertSpatialPlacement(surfaceID, frame, world_origin);
      const board = await store.replaceBoard({
        expectedRevision: expected_revision,
        transform: (current, workspace, actor) => {
          assertKnownSurface(surfaceID, workspace);
          const element = spatialElement({
            id,
            surface: surfaceID,
            frame,
            worldOrigin: world_origin,
            kind: "web",
            source: html,
            html,
            css,
            javaScript: javascript,
            state: state as JSONValue,
            stamp: nextVersionStamp(current.stamp, actor),
          });
          current.elements = upsertSpatial(current.elements, element);
          return current;
        },
      });
      return spatialMutationReceipt(board, id);
    }),
  );

  server.registerTool(
    "tetrad_remove_spatial_elements",
    {
      title: "Remove layers from the board or covers",
      description: "Remove named agent-authored spatial layers while preserving Pencil ink.",
      inputSchema: z.object({
        expected_revision: z.string().min(1).describe("boardRevision from tetrad_read_board."),
        ids: z.array(z.string().trim().min(1)).min(1),
      }),
    },
    ({ expected_revision, ids }) => safely(async () => {
      const remove = new Set(ids);
      let removed = 0;
      const board = await store.replaceBoard({
        expectedRevision: expected_revision,
        transform: (current) => {
          current.elements = current.elements.filter((element) => {
            if (!remove.has(element.id)) return true;
            removed += 1;
            return false;
          });
          return current;
        },
      });
      return { removed, boardRevision: revision(board.stamp) };
    }),
  );

  server.registerTool(
    "tetrad_read_page",
    {
      title: "Read a Tetrad page",
      description:
        "Read page size and all agent-authored Markdown, SVG, CSS, JavaScript, and interactive state. " +
        "Call tetrad_render_page to see Pencil handwriting.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id }) => safely(async () => {
      const page = page_id
        ? await store.readPage(page_id)
        : (await store.readCurrent()).page;
      return publicPage(page);
    }),
  );

  server.registerTool(
    "tetrad_render_page",
    {
      title: "See Pencil handwriting",
      description:
        "Return a PNG of the faint grid and Apple Pencil drawing. " +
        "Agent-authored web layers are returned as source by tetrad_read_page.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id }) => safely(async () => {
      const page = page_id
        ? await store.readPage(page_id)
        : (await store.readCurrent()).page;
      let png: Buffer;
      let renderedRevision: string;
      try {
        [png, renderedRevision] = await Promise.all([
          readFile(store.previewPath(page.id)),
          readFile(store.previewRevisionPath(page.id), "utf8"),
        ]);
      } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === "ENOENT") {
          throw new StoreError(
            "Предпросмотр еще не создан. Откройте «Тетрадь» на Mac и оставьте ее запущенной.",
          );
        }
        throw error;
      }
      const currentRevision = revision(page.drawingStamp);
      if (renderedRevision.trim() !== currentRevision) {
        throw new StoreError(
          "Предпросмотр догоняет новый штрих. Повторите tetrad_render_page через мгновение.",
        );
      }
      return {
        data: {
          pageID: page.id,
          drawingRevision: currentRevision,
          pixelEncoding: "image/png",
        },
        image: png.toString("base64"),
      };
    }, true),
  );

  server.registerTool(
    "tetrad_put_markdown",
    {
      title: "Put Markdown on a Tetrad page",
      description:
        "Create or replace one transparent Markdown layer. The frame is in page points; there is no card, border, or toolbar.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        markdown: z.string(),
        css: z.string().default(""),
      }),
    },
    ({ page_id, expected_revision, id, frame, markdown, css }) => safely(async () => {
      const element: AgentElement = {
        id,
        kind: "markdown",
        frame,
        source: markdown,
        html: await marked.parse(markdown, { async: true, gfm: true }),
        css,
        javaScript: "",
        state: {},
      };
      const page = await store.replaceElements({
        pageID: page_id,
        expectedRevision: expected_revision,
        transform: (elements, currentPage) => {
          assertFrame(frame, currentPage);
          return upsert(elements, element);
        },
      });
      return mutationReceipt(page, element.id);
    }),
  );

  server.registerTool(
    "tetrad_put_web",
    {
      title: "Put an interactive web layer on a Tetrad page",
      description:
        "Create or replace one transparent HTML/SVG/CSS/JavaScript layer. " +
        "Use window.tetrad.state to read state and window.tetrad.commit(value) after a user action. " +
        "The layer has no surrounding UI and cannot use the network.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        html: z.string(),
        css: z.string().default(""),
        javascript: z.string().default(""),
        state: z.json().default({}),
      }),
    },
    ({ page_id, expected_revision, id, frame, html, css, javascript, state }) =>
      safely(async () => {
        assertJavaScript(javascript);
        const element: AgentElement = {
          id,
          kind: "web",
          frame,
          source: html,
          html,
          css,
          javaScript: javascript,
          state: state as JSONValue,
        };
        const page = await store.replaceElements({
          pageID: page_id,
          expectedRevision: expected_revision,
          transform: (elements, currentPage) => {
            assertFrame(frame, currentPage);
            return upsert(elements, element);
          },
        });
        return mutationReceipt(page, element.id);
      }),
  );

  server.registerTool(
    "tetrad_remove_elements",
    {
      title: "Remove layers from a Tetrad page",
      description: "Remove named agent-authored layers while preserving the Pencil drawing.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        ids: z.array(z.string().trim().min(1)).min(1),
      }),
    },
    ({ page_id, expected_revision, ids }) => safely(async () => {
      const remove = new Set(ids);
      let removed = 0;
      const page = await store.replaceElements({
        pageID: page_id,
        expectedRevision: expected_revision,
        transform: (elements) => elements.filter((element) => {
          if (!remove.has(element.id)) return true;
          removed += 1;
          return false;
        }),
      });
      return {
        pageID: page.id,
        removed,
        agentRevision: revision(page.agentStamp),
      };
    }),
  );

  return server;
}

function visibleNotebooks(
  workspace: WorkspaceIndex,
  board: BoardDocument,
  presence: SessionPresence,
): object[] {
  const byID = new Map(
    workspace.notebooks.map((notebook) => [notebook.id.toLowerCase(), notebook]),
  );
  const rendered: Array<{
    notebookID: string;
    title: string;
    center: WorldPoint;
    zIndex: number;
    stackID: string | null;
  }> = [];
  for (const placement of board.freeNotebooks) {
    const notebook = byID.get(placement.notebookID.toLowerCase());
    if (!notebook) continue;
    rendered.push({
      notebookID: notebook.id,
      title: notebook.title,
      center: placement.center,
      zIndex: placement.zIndex,
      stackID: null,
    });
  }
  for (const stack of board.stacks) {
    const projectedHeight = 1_194 * presence.camera.scale;
    const fan = clamp((projectedHeight - 160) / 440, 0, 1);
    for (const [index, notebookID] of stack.notebookIDs.entries()) {
      const notebook = byID.get(notebookID.toLowerCase());
      if (!notebook) continue;
      const centered = index - (stack.notebookIDs.length - 1) / 2;
      const collapsedX = centered * 9 / Math.max(presence.camera.scale, 0.001);
      const collapsedY = -index * 7 / Math.max(presence.camera.scale, 0.001);
      const fannedX = centered * 834 * 0.62;
      const fannedY = Math.abs(centered) * 1_194 * 0.08;
      rendered.push({
        notebookID: notebook.id,
        title: notebook.title,
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
  const width = 834 * presence.camera.scale;
  const height = 1_194 * presence.camera.scale;
  return rendered
    .sort((first, second) => first.zIndex - second.zIndex)
    .map((item) => {
      const center = worldToScreen(item.center, presence);
      return {
        ...item,
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

function assertFreshCurrentView(
  receipt: CurrentViewReceipt,
  workspaceStamp: VersionStamp,
  boardStamp: VersionStamp,
  spatialInkStamp: VersionStamp,
  presence: SessionPresence,
): void {
  if (!sameStamp(receipt.workspaceStamp, workspaceStamp)
    || !sameStamp(receipt.boardStamp, boardStamp)
    || !sameStamp(receipt.spatialInkStamp, spatialInkStamp)
    || !isDeepStrictEqual(receipt.presence, presence)) {
    throw new StoreError(
      "Изображение текущего вида догоняет изменения. Повторите tetrad_render_view через мгновение.",
    );
  }
}

function moveNode(
  board: BoardDocument,
  kind: "notebook" | "stack",
  id: string,
  center: WorldPoint,
  actor: string,
): void {
  const stamp = nextVersionStamp(board.stamp, actor);
  if (kind === "stack") {
    const stack = board.stacks.find((candidate) => sameID(candidate.id, id));
    if (!stack) throw new StoreError(`Стопка не найдена: ${id}`);
    stack.center = center;
    stack.zIndex = boardHighestZIndex(board) + 1;
    stack.stamp = stamp;
    return;
  }

  const placement = board.freeNotebooks.find(
    (candidate) => sameID(candidate.notebookID, id),
  );
  if (placement) {
    placement.center = center;
    placement.zIndex = boardHighestZIndex(board) + 1;
    placement.stamp = stamp;
    return;
  }

  const stackIndex = board.stacks.findIndex(
    (candidate) => candidate.notebookIDs.some((notebookID) => sameID(notebookID, id)),
  );
  if (stackIndex < 0) throw new StoreError(`Тетрадь не найдена: ${id}`);
  const stack = board.stacks[stackIndex]!;
  stack.notebookIDs = stack.notebookIDs.filter((notebookID) => !sameID(notebookID, id));
  board.freeNotebooks.push({
    notebookID: id,
    center,
    zIndex: boardHighestZIndex(board) + 1,
    stamp,
  });
  if (stack.notebookIDs.length === 1) {
    const remaining = stack.notebookIDs[0]!;
    board.freeNotebooks.push({
      notebookID: remaining,
      center: stack.center,
      zIndex: stack.zIndex,
      stamp,
    });
    board.stacks.splice(stackIndex, 1);
  } else {
    stack.stamp = stamp;
  }
}

function stackNotebook(
  board: BoardDocument,
  movingID: string,
  targetID: string,
  actor: string,
): string {
  const movingIndex = board.freeNotebooks.findIndex(
    (placement) => sameID(placement.notebookID, movingID),
  );
  if (movingIndex < 0) {
    throw new StoreError("Перемещаемая тетрадь должна свободно лежать на доске.");
  }
  const stamp = nextVersionStamp(board.stamp, actor);
  const targetStack = board.stacks.find(
    (stack) => stack.notebookIDs.some((notebookID) => sameID(notebookID, targetID)),
  );
  if (targetStack) {
    targetStack.notebookIDs.push(board.freeNotebooks[movingIndex]!.notebookID);
    targetStack.stamp = stamp;
    board.freeNotebooks.splice(movingIndex, 1);
    return targetStack.id;
  }

  const targetIndex = board.freeNotebooks.findIndex(
    (placement) => sameID(placement.notebookID, targetID),
  );
  if (targetIndex < 0) throw new StoreError("Целевая тетрадь не найдена.");
  const moving = board.freeNotebooks[movingIndex]!;
  const target = board.freeNotebooks[targetIndex]!;
  for (const index of [movingIndex, targetIndex].sort((a, b) => b - a)) {
    board.freeNotebooks.splice(index, 1);
  }
  const stackID = randomUUID();
  board.stacks.push({
    id: stackID,
    center: target.center,
    zIndex: Math.max(moving.zIndex, target.zIndex) + 1,
    notebookIDs: [target.notebookID, moving.notebookID],
    stamp,
  });
  return stackID;
}

function inputSurface(
  value: { kind: "board" } | { kind: "cover"; notebook_id: string },
): SurfaceID {
  return value.kind === "board"
    ? { kind: "board" }
    : { kind: "cover", ownerID: value.notebook_id };
}

function assertSpatialPlacement(
  surface: SurfaceID,
  frame: { x: number; y: number; width: number; height: number },
  worldOrigin: WorldPoint | undefined,
): void {
  assertSpatialFrame(frame, surface);
  if (surface.kind === "board" && !worldOrigin) {
    throw new StoreError("Элементу доски нужен world_origin.");
  }
  if (surface.kind === "cover" && worldOrigin) {
    throw new StoreError("Элемент обложки использует только локальный frame.");
  }
}

function assertKnownSurface(surface: SurfaceID, workspace: WorkspaceIndex): void {
  if (surface.kind === "cover" && !workspace.notebooks.some(
    (notebook) => sameID(notebook.id, surface.ownerID!),
  )) {
    throw new StoreError("Обложка не найдена.");
  }
}

function spatialElement(args: {
  id: string;
  surface: SurfaceID;
  frame: { x: number; y: number; width: number; height: number };
  worldOrigin?: WorldPoint | undefined;
  kind: "markdown" | "web";
  source: string;
  html: string;
  css: string;
  javaScript: string;
  state: JSONValue;
  stamp: VersionStamp;
}): SpatialElement {
  return {
    id: args.id,
    surface: args.surface,
    kind: args.kind,
    frame: args.frame,
    ...(args.worldOrigin ? { worldOrigin: args.worldOrigin } : {}),
    source: args.source,
    html: args.html,
    css: args.css,
    javaScript: args.javaScript,
    state: args.state,
    textStyle: {
      fontSize: 34,
      weight: 0.45,
      red: 0.09,
      green: 0.09,
      blue: 0.08,
      alpha: 1,
    },
    stamp: args.stamp,
  };
}

function upsertSpatial(
  elements: SpatialElement[],
  replacement: SpatialElement,
): SpatialElement[] {
  const index = elements.findIndex((element) => element.id === replacement.id);
  if (index < 0) return [...elements, replacement];
  const next = [...elements];
  next[index] = replacement;
  return next;
}

function spatialMutationReceipt(board: BoardDocument, elementID: string): object {
  return {
    elementID,
    boardRevision: revision(board.stamp),
  };
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

function upsert(elements: AgentElement[], replacement: AgentElement): AgentElement[] {
  const index = elements.findIndex((element) => element.id === replacement.id);
  if (index < 0) return [...elements, replacement];
  const next = [...elements];
  next[index] = replacement;
  return next;
}

function mutationReceipt(page: PageDocument, elementID: string): object {
  return {
    pageID: page.id,
    elementID,
    agentRevision: revision(page.agentStamp),
  };
}

function assertJavaScript(source: string): void {
  try {
    // This compiles the body only. Execution remains inside WKWebView's local CSP sandbox.
    Function(source);
  } catch (error) {
    throw new StoreError(`JavaScript содержит синтаксическую ошибку: ${(error as Error).message}`);
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
    return {
      content: [{ type: "text", text: message }],
      isError: true,
    };
  }
}
