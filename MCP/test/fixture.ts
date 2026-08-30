import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type {
  BoardDocument,
  CurrentViewReceipt,
  PageDocument,
  SessionPresence,
  SpatialInkJournal,
  WorkspaceIndex,
} from "../src/domain.js";

export const notebookID = "7e7a0000-0000-4000-8000-000000000001";
export const pageID = "7e7a0000-0000-4000-8000-000000000002";
export const appActor = "7e7a0000-0000-4000-8000-000000000003";

export async function writeFixture(root: string): Promise<void> {
  const previewPNG = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nH0AAAAASUVORK5CYII=",
    "base64",
  );
  const workspace: WorkspaceIndex = {
    format: 1,
    notebooks: [{ id: notebookID, title: "Notebook 1", pageIDs: [pageID] }],
    selectedNotebookID: notebookID,
    selectedPageID: pageID,
    stamp: { counter: 0, actor: appActor },
  };
  const page: PageDocument = {
    format: 1,
    id: pageID,
    size: { width: 834, height: 1194 },
    drawingData: "",
    drawingStamp: { counter: 0, actor: appActor },
    elements: [],
    agentStamp: { counter: 0, actor: appActor },
  };
  const board: BoardDocument = {
    format: 1,
    freeNotebooks: [{
      notebookID,
      center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
      zIndex: 0,
      stamp: { counter: 0, actor: appActor },
    }],
    stacks: [],
    elements: [],
    stamp: { counter: 0, actor: appActor },
  };
  const spatialInk: SpatialInkJournal = {
    format: 1,
    actions: [],
    stamp: { counter: 0, actor: appActor },
  };
  const presence: SessionPresence = {
    format: 1,
    mode: "page",
    camera: {
      center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
      scale: 0.8,
    },
    viewport: { x: 834, y: 1_194 },
    focusedNotebookID: notebookID,
    openProgress: 1,
  };
  const currentViewReceipt: CurrentViewReceipt = {
    format: 1,
    workspaceStamp: workspace.stamp,
    boardStamp: board.stamp,
    spatialInkStamp: spatialInk.stamp,
    presence,
    renderViewport: { x: 700, y: 900 },
    pngSHA256: createHash("sha256").update(previewPNG).digest("hex"),
    page: {
      pageID,
      drawingStamp: page.drawingStamp,
      agentStamp: page.agentStamp,
    },
  };
  await mkdir(join(root, "pages"), { recursive: true });
  await mkdir(join(root, "previews"), { recursive: true });
  await writeFile(join(root, "workspace.json"), JSON.stringify(workspace));
  await writeFile(join(root, "board.json"), JSON.stringify(board));
  await writeFile(join(root, "spatial-ink.json"), JSON.stringify(spatialInk));
  await writeFile(join(root, "last-context.json"), JSON.stringify(presence));
  await writeFile(join(root, "pages", `${pageID}.json`), JSON.stringify(page));
  // A minimal valid PNG is sufficient for MCP content-path verification.
  await writeFile(
    join(root, "previews", `${pageID}.png`),
    previewPNG,
  );
  await writeFile(
    join(root, "previews", `${pageID}.revision`),
    `0@${appActor}\n`,
  );
  await writeFile(
    join(root, "previews", "current-view.png"),
    previewPNG,
  );
  await writeFile(
    join(root, "previews", "current-view.revision"),
    JSON.stringify(currentViewReceipt),
  );
}
