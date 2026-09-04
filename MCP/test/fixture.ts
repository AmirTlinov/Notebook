import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { deflateSync } from "node:zlib";

import type {
  BoardHierarchy,
  CurrentViewReceipt,
  PageDocument,
  SessionPresence,
  SpatialInkJournal,
  WorkspaceIndex,
} from "../src/domain.js";
import type { PageVisionReceipt } from "../src/page-vision.js";

export const itemID = "7e7a0000-0000-4000-8000-000000000001";
export const pageID = "7e7a0000-0000-4000-8000-000000000002";
export const appActor = "7e7a0000-0000-4000-8000-000000000003";
export const rootBoardID = "7e7a0000-0000-4000-8000-000000000003";

const previewPNG = grayscalePNG(1_668, 2_388, 255);
const currentViewPNG = grayscalePNG(700, 900, 96);
const regionPNG = grayscalePNG(52, 52, 0);

export async function writeFixture(root: string): Promise<void> {
  const workspace: WorkspaceIndex = {
    format: 3,
    rootBoardID,
    items: [
      {
        id: itemID,
        kind: "notebook",
        title: "Notebook 1",
        pageIDs: [pageID],
      },
    ],
    selectedItemID: itemID,
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
  const board: BoardHierarchy = {
    format: 1,
    rootBoardID,
    boards: [{
      id: rootBoardID,
      board: {
        format: 2,
        freeItems: [
          {
            itemID,
            center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
            zIndex: 0,
            stamp: { counter: 0, actor: appActor },
          },
        ],
        stacks: [],
        elements: [],
        stamp: { counter: 0, actor: appActor },
      },
    }],
    stamp: { counter: 0, actor: appActor },
  };
  const spatialInk: SpatialInkJournal = {
    format: 1,
    actions: [],
    stamp: { counter: 0, actor: appActor },
  };
  const presence: SessionPresence = {
    format: 4,
    boardID: rootBoardID,
    mode: "page",
    camera: {
      center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
      scale: 0.8,
    },
    viewport: { x: 834, y: 1_194 },
    focusedItemID: itemID,
    openProgress: 1,
    documentPageIndex: 0,
  };
  const currentViewReceipt: CurrentViewReceipt = {
    format: 4,
    workspaceStamp: workspace.stamp,
    boardStamp: board.stamp,
    spatialInkStamp: spatialInk.stamp,
    presence,
    renderViewport: { x: 700, y: 900 },
    pngSHA256: createHash("sha256").update(currentViewPNG).digest("hex"),
    surface: {
      kind: "page",
      itemID,
      revision: {
        pageID,
        drawingStamp: page.drawingStamp,
        agentStamp: page.agentStamp,
      },
      snapshotPNG_SHA256: createHash("sha256").update(previewPNG).digest("hex"),
    },
  };
  const previewSHA256 = createHash("sha256").update(previewPNG).digest("hex");
  const regionSHA256 = createHash("sha256").update(regionPNG).digest("hex");
  const gridSpacing = 132 / 2.54 / 2;
  const visionReceipt: PageVisionReceipt = {
    format: 1,
    pageID,
    drawingStamp: page.drawingStamp,
    pageSize: page.size,
    renderScale: 2,
    gridSpacing,
    gridColumns: Math.ceil(page.size.width / gridSpacing),
    gridRows: Math.ceil(page.size.height / gridSpacing),
    pixelSize: { width: 1_668, height: 2_388 },
    visibleInkBounds: { x: 0, y: 0, width: 1, height: 1 },
    occupiedCells: [{ column: 0, row: 0 }],
    regions: [
      {
        id: "r00-00-01-01",
        contentCells: { column: 0, row: 0, width: 1, height: 1 },
        cropCells: { column: 0, row: 0, width: 1, height: 1 },
        contentPoints: { x: 0, y: 0, width: gridSpacing, height: gridSpacing },
        cropPoints: { x: 0, y: 0, width: gridSpacing, height: gridSpacing },
        cropPixels: { x: 0, y: 0, width: 52, height: 52 },
        inkPixelCount: 1,
        faithfulPNG_SHA256: regionSHA256,
        inkPNG_SHA256: regionSHA256,
      },
    ],
    previewPNG_SHA256: previewSHA256,
    inkPNG_SHA256: previewSHA256,
  };
  await mkdir(join(root, "pages"), { recursive: true });
  await mkdir(join(root, "previews"), { recursive: true });
  await mkdir(join(root, "previews", `${pageID}.regions`), { recursive: true });
  await writeFile(join(root, "workspace.json"), JSON.stringify(workspace));
  await writeFile(join(root, "board.json"), JSON.stringify(board));
  await writeFile(join(root, "spatial-ink.json"), JSON.stringify(spatialInk));
  await writeFile(join(root, "last-context.json"), JSON.stringify(presence));
  await writeFile(join(root, "pages", `${pageID}.json`), JSON.stringify(page));
  // A minimal valid PNG is sufficient for MCP content-path verification.
  await writeFile(join(root, "previews", `${pageID}.png`), previewPNG);
  await writeFile(join(root, "previews", `${pageID}.ink.png`), previewPNG);
  await writeFile(
    join(root, "previews", `${pageID}.vision.json`),
    JSON.stringify(visionReceipt),
  );
  for (const mode of ["faithful", "ink"]) {
    await writeFile(
      join(root, "previews", `${pageID}.regions`, `r00-00-01-01.${mode}.png`),
      regionPNG,
    );
  }
  await writeFile(join(root, "previews", "current-view.png"), currentViewPNG);
  await writeFile(
    join(root, "previews", "current-view.revision"),
    JSON.stringify(currentViewReceipt),
  );
}

function grayscalePNG(width: number, height: number, value: number): Buffer {
  const bytesPerRow = width + 1;
  const pixels = Buffer.alloc(bytesPerRow * height, value);
  for (let row = 0; row < height; row += 1) {
    pixels[row * bytesPerRow] = 0;
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 0;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(pixels)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function pngChunk(type: string, data: Buffer): Buffer {
  const name = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([length, name, data, checksum]);
}

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
