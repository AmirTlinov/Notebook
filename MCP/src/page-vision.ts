import { notebookResponseSchema } from "./contracts.js";
import { BridgeError, runBridge } from "./bridge.js";
import { createHash } from "node:crypto";

import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

import type { PageDocument } from "./domain.js";
import { revision } from "./domain.js";
import { NotebookStore, StoreError } from "./store.js";

const physicalGridSpacing = 132 / 2.54 / 2;
const maximumPageDimension = 2_048;
const maximumRenderScale = 16;
const maximumRegionCellSpan = 12;
const sha256Schema = z.string().regex(/^[0-9a-f]{64}$/);
const stampSchema = z
  .object({
    counter: z.number().int().safe().nonnegative(),
    actor: z.uuid(),
  })
  .strict();
const pageRectSchema = z
  .object({
    x: z.number().finite().nonnegative(),
    y: z.number().finite().nonnegative(),
    width: z.number().finite().positive(),
    height: z.number().finite().positive(),
  })
  .strict();
const cellSchema = z
  .object({
    column: z.number().int().safe().nonnegative(),
    row: z.number().int().safe().nonnegative(),
  })
  .strict();
const cellFrameSchema = z
  .object({
    column: z.number().int().safe().nonnegative(),
    row: z.number().int().safe().nonnegative(),
    width: z.number().int().safe().positive(),
    height: z.number().int().safe().positive(),
  })
  .strict();
const pixelFrameSchema = z
  .object({
    x: z.number().int().safe().nonnegative(),
    y: z.number().int().safe().nonnegative(),
    width: z.number().int().safe().positive(),
    height: z.number().int().safe().positive(),
  })
  .strict();
const regionIDSchema = z.string().regex(/^r\d{2,}-\d{2,}-\d{2,}-\d{2,}$/);
const regionSchema = z
  .object({
    id: regionIDSchema,
    contentCells: cellFrameSchema,
    cropCells: cellFrameSchema,
    contentPoints: pageRectSchema,
    cropPoints: pageRectSchema,
    cropPixels: pixelFrameSchema,
    inkPixelCount: z.number().int().safe().positive(),
    faithfulPNG_SHA256: sha256Schema,
    inkPNG_SHA256: sha256Schema,
  })
  .strict();
const receiptSchema = z
  .object({
    format: z.literal(2),
    pageID: z.uuid(),
    drawingStamp: stampSchema,
    pageSize: z
      .object({
        width: z.number().finite().positive().max(maximumPageDimension),
        height: z.number().finite().positive().max(maximumPageDimension),
      })
      .strict(),
    renderScale: z.number().finite().positive().max(maximumRenderScale),
    gridSpacing: z.number().finite().positive(),
    gridColumns: z.number().int().positive(),
    gridRows: z.number().int().positive(),
    pixelSize: z
      .object({
        width: z.number().int().positive(),
        height: z.number().int().positive(),
      })
      .strict(),
    visibleInkBounds: pageRectSchema.nullable().optional(),
    occupiedCells: z.array(cellSchema),
    regions: z.array(regionSchema),
    previewPNG_SHA256: sha256Schema,
    inkPNG_SHA256: sha256Schema,
  })
  .strict();

export type PageVisionReceipt = z.infer<typeof receiptSchema>;
type PageVisionRegion = z.infer<typeof regionSchema>;
type VisionMode = "faithful" | "ink";

class PageVisionPending extends StoreError {
  constructor(readonly requestID: string) {
    super("Карта указанного листа собирается в фоне. Это не означает, что Амир сейчас рисует. Повторите notebook_page_map через мгновение.");
  }
}

async function requestPageVision(store: NotebookStore, page: PageDocument): Promise<never> {
  const request = await runBridge<{ id: string }>(store.socketPath, { command: "pageVision",
    target: { kind: "page", id: page.id }, expectedRevision: revision(page.drawingStamp) });
  const receipt = await store.readTargetRenderReceipt<{ status?: string; diagnostics?: Array<{ message?: string }> }>(request.id);
  if (receipt?.status === "error") {
    throw new StoreError("Подготовка карты завершилась ошибкой: " +
      (receipt.diagnostics?.slice(0, 3).map(value => value.message ?? "Ошибка исполнения").join("; ") ?? "Ошибка исполнения"));
  }
  throw new PageVisionPending(request.id);
}

const pageSelection = {
  page_id: z
    .uuid()
    .optional()
    .describe("UUID страницы; по умолчанию текущая страница."),
  notebook_id: z.uuid().optional().describe("UUID тетради для выбора по номеру."),
  page_number: z.number().int().positive().optional().describe("Номер листа от 1."),
};
const expectedRevision = {
  expected_drawing_revision: z
    .string()
    .min(1)
    .optional()
    .describe(
      "drawingRevision из notebook_page_map. Если лист изменился, изображение не возвращается.",
    ),
};
const sinceRevision = {
  since_drawing_revision: z
    .string()
    .min(1)
    .optional()
    .describe(
      "Предыдущий drawingRevision. Notebook укажет изменившиеся и исчезнувшие области, если эта карта еще хранится.",
    ),
};

export function registerPageVisionTools(
  server: McpServer,
  store: NotebookStore,
): void {
  server.registerTool(
    "notebook_page_map",
    {
      outputSchema: notebookResponseSchema,
      title: "Locate visible Pencil ink",
      description:
        "Return the physical 0.5 cm grid cells and grouped regions containing visible Pencil pixels. " +
        "Call this before requesting detail images; erased PKStroke paths are excluded. " +
        "A cold or stale map queues only this page and returns pending; it does not prepare the archive.",
      inputSchema: z.object({ ...pageSelection, ...sinceRevision }),
    },
    ({ page_id, notebook_id, page_number, since_drawing_revision }) =>
      visionSafely(async () => {
        const page = await resolvePage(store, page_id, notebook_id, page_number);
        const receipt = await readFreshPageVision(store, page);
        const previous = since_drawing_revision
          ? await readHistoricalPageVision(
              store,
              page.id,
              since_drawing_revision,
              receipt,
            )
          : undefined;
        return publicPageMap(receipt, since_drawing_revision, previous);
      }),
  );

  server.registerTool(
    "notebook_render_region",
    {
      outputSchema: notebookResponseSchema,
      title: "Magnify one Pencil region",
      description:
        "Return one exact pre-cropped region from notebook_page_map. " +
        "Faithful mode preserves the physical appearance. Ink mode removes the grid and doubles ink-to-white contrast for reading.",
      inputSchema: z.object({
        ...pageSelection,
        ...expectedRevision,
        region_id: regionIDSchema,
        mode: z.enum(["faithful", "ink"]).default("faithful"),
      }),
    },
    ({
      page_id,
      notebook_id,
      page_number,
      expected_drawing_revision,
      region_id,
      mode,
    }) =>
      visionImageSafely(async () => {
        const page = await resolvePage(store, page_id, notebook_id, page_number);
        const receipt = await readFreshPageVision(
          store,
          page,
          expected_drawing_revision,
        );
        const region = findRegion(receipt, region_id);
        const image = await readVerifiedRegion(store, receipt, region, mode);
        return {
          data: publicRenderedRegions(receipt, [region], mode),
          images: [image.toString("base64")],
        };
      }),
  );

  server.registerTool(
    "notebook_render_regions",
    {
      outputSchema: notebookResponseSchema,
      title: "Magnify several Pencil regions",
      description:
        "Return up to four exact region images in the requested order, avoiding repeated full-page screenshots.",
      inputSchema: z.object({
        ...pageSelection,
        ...expectedRevision,
        region_ids: z.array(regionIDSchema).min(1).max(4),
        mode: z.enum(["faithful", "ink"]).default("faithful"),
      }),
    },
    ({
      page_id,
      notebook_id,
      page_number,
      expected_drawing_revision,
      region_ids,
      mode,
    }) =>
      visionImageSafely(async () => {
        if (new Set(region_ids).size !== region_ids.length) {
          throw new StoreError("Каждую область достаточно запросить один раз.");
        }
        const page = await resolvePage(store, page_id, notebook_id, page_number);
        const receipt = await readFreshPageVision(
          store,
          page,
          expected_drawing_revision,
        );
        const regions = region_ids.map((id) => findRegion(receipt, id));
        const images = await Promise.all(
          regions.map((region) =>
            readVerifiedRegion(store, receipt, region, mode),
          ),
        );
        return {
          data: publicRenderedRegions(receipt, regions, mode),
          images: images.map((image) => image.toString("base64")),
        };
      }),
  );
}

export async function readFreshPageVision(
  store: NotebookStore,
  page: PageDocument,
  expectedDrawingRevision?: string,
): Promise<PageVisionReceipt> {
  const currentRevision = revision(page.drawingStamp);
  if (expectedDrawingRevision && expectedDrawingRevision !== currentRevision) {
    throw new StoreError("Лист изменился после карты. Сначала снова вызовите notebook_page_map.");
  }
  const stored = await store.readPageVisionReceipt(page.id);
  if (!stored) return requestPageVision(store, page);
  const parsed = receiptSchema.safeParse(stored);
  if (!parsed.success) {
    throw new StoreError(
      "Квитанция карты листа не соответствует контракту Notebook.",
    );
  }
  const receipt = parsed.data;
  if (!isReceiptInternallyValid(receipt)) {
    throw new StoreError(
      "Квитанция карты листа содержит противоречивую геометрию.",
    );
  }
  if (
    !sameID(receipt.pageID, page.id) ||
    revision(receipt.drawingStamp) !== currentRevision ||
    receipt.pageSize.width !== page.size.width ||
    receipt.pageSize.height !== page.size.height
  ) {
    return requestPageVision(store, page);
  }
  return receipt;
}

export async function readVerifiedPageOverview(
  store: NotebookStore,
  receipt: PageVisionReceipt,
  mode: VisionMode,
): Promise<Buffer> {
  const expectedSHA256 = mode === "faithful" ? receipt.previewPNG_SHA256 : receipt.inkPNG_SHA256;
  return readVerifiedPNG(store, receipt, {kind:"pageOverview",id:receipt.pageID,mode,expectedSHA256}, receipt.pixelSize);
}

function publicPageMap(
  receipt: PageVisionReceipt,
  sinceDrawingRevision?: string,
  previous?: PageVisionReceipt | null,
): object {
  const previousRegions = new Map(
    previous?.regions.map((region) => [region.id, region]) ?? [],
  );
  const currentRegions = new Map(
    receipt.regions.map((region) => [region.id, region]),
  );
  const unchangedRegionIDs = previous
    ? receipt.regions
        .filter(
          (region) =>
            previousRegions.get(region.id)?.inkPNG_SHA256 ===
            region.inkPNG_SHA256,
        )
        .map((region) => region.id)
    : [];
  const unchanged = new Set(unchangedRegionIDs);
  const changedRegionIDs = previous
    ? receipt.regions
        .filter((region) => !unchanged.has(region.id))
        .map((region) => region.id)
    : [];
  const removedRegionIDs = previous
    ? previous.regions
        .filter((region) => !currentRegions.has(region.id))
        .map((region) => region.id)
    : [];
  return {
    pageID: receipt.pageID,
    drawingRevision: revision(receipt.drawingStamp),
    inkBlank: receipt.regions.length === 0,
    coordinateSystem: {
      origin: "top-left",
      cellSizeCentimeters: 0.5,
      gridSpacingPoints: receipt.gridSpacing,
      sourcePixelsPerCell: receipt.gridSpacing * receipt.renderScale,
      columns: receipt.gridColumns,
      rows: receipt.gridRows,
    },
    pageSizePoints: receipt.pageSize,
    sourcePixelSize: receipt.pixelSize,
    visibleInkBoundsPoints: receipt.visibleInkBounds ?? null,
    occupiedCells: receipt.occupiedCells,
    delta: sinceDrawingRevision
      ? {
          fromDrawingRevision: sinceDrawingRevision,
          available: previous !== null,
          changedRegionIDs,
          removedRegionIDs,
          unchangedRegionIDs,
        }
      : null,
    regions: receipt.regions.map((region) => ({
      id: region.id,
      contentCells: region.contentCells,
      cropCells: region.cropCells,
      contentPoints: region.contentPoints,
      cropPoints: region.cropPoints,
      cropPixels: region.cropPixels,
      inkPixelCount: region.inkPixelCount,
      contentSHA256: region.inkPNG_SHA256,
    })),
  };
}

async function readHistoricalPageVision(
  store: NotebookStore,
  pageID: string,
  requestedRevision: string,
  current: PageVisionReceipt,
): Promise<PageVisionReceipt | null> {
  if (requestedRevision === revision(current.drawingStamp)) return current;
  const match =
    /^(\d+)@([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i.exec(
      requestedRevision,
    );
  if (!match) {
    throw new StoreError("since_drawing_revision имеет неверный формат.");
  }
  let stored: unknown;
  try { stored = await store.readPageVisionReceipt(pageID, requestedRevision); }
  catch (error) { if (error instanceof BridgeError && error.detail.code === "invalid_artifact") return null; throw error; }
  const parsed = receiptSchema.safeParse(stored);
  if (
    !parsed.success ||
    !sameID(parsed.data.pageID, pageID) ||
    revision(parsed.data.drawingStamp) !== requestedRevision ||
    !isReceiptInternallyValid(parsed.data)
  ) {
    return null;
  }
  return parsed.data;
}

function isReceiptInternallyValid(receipt: PageVisionReceipt): boolean {
  const expectedColumns = Math.ceil(
    receipt.pageSize.width / receipt.gridSpacing,
  );
  const expectedRows = Math.ceil(receipt.pageSize.height / receipt.gridSpacing);
  const expectedPixelWidth = Math.max(
    1,
    Math.round(receipt.pageSize.width * receipt.renderScale),
  );
  const expectedPixelHeight = Math.max(
    1,
    Math.round(receipt.pageSize.height * receipt.renderScale),
  );
  if (
    receipt.gridSpacing !== physicalGridSpacing ||
    receipt.gridColumns !== expectedColumns ||
    receipt.gridRows !== expectedRows ||
    receipt.pixelSize.width !== expectedPixelWidth ||
    receipt.pixelSize.height !== expectedPixelHeight
  ) {
    return false;
  }
  if (
    receipt.visibleInkBounds &&
    !rectContained(receipt.visibleInkBounds, receipt.pageSize)
  ) {
    return false;
  }
  const cellKeys = receipt.occupiedCells.map(
    (cell) => `${cell.row}:${cell.column}`,
  );
  const orderedKeys = [...cellKeys].sort((left, right) => {
    const [leftRow, leftColumn] = left.split(":").map(Number);
    const [rightRow, rightColumn] = right.split(":").map(Number);
    return leftRow! - rightRow! || leftColumn! - rightColumn!;
  });
  if (
    new Set(cellKeys).size !== cellKeys.length ||
    cellKeys.some((key, index) => key !== orderedKeys[index]) ||
    receipt.occupiedCells.some(
      (cell) =>
        cell.column >= receipt.gridColumns || cell.row >= receipt.gridRows,
    ) ||
    (receipt.visibleInkBounds == null) !==
      (receipt.occupiedCells.length === 0) ||
    (receipt.regions.length === 0) !== (receipt.occupiedCells.length === 0)
  ) {
    return false;
  }
  if (
    new Set(receipt.regions.map((region) => region.id)).size !==
    receipt.regions.length
  ) {
    return false;
  }
  if (
    receipt.occupiedCells.some(
      (cell) =>
        !receipt.regions.some((region) =>
          cellInFrame(cell, region.contentCells),
        ),
    )
  ) {
    return false;
  }
  return receipt.regions.every(
    (region) =>
      region.id === regionID(region.contentCells) &&
      cellFrameContained(
        region.contentCells,
        receipt.gridColumns,
        receipt.gridRows,
      ) &&
      region.contentCells.width <= maximumRegionCellSpan &&
      region.contentCells.height <= maximumRegionCellSpan &&
      cellFrameContained(
        region.cropCells,
        receipt.gridColumns,
        receipt.gridRows,
      ) &&
      cellInFrame(
        { column: region.contentCells.column, row: region.contentCells.row },
        region.cropCells,
      ) &&
      cellInFrame(
        {
          column: region.contentCells.column + region.contentCells.width - 1,
          row: region.contentCells.row + region.contentCells.height - 1,
        },
        region.cropCells,
      ) &&
      sameRect(
        region.contentPoints,
        pointFrame(region.contentCells, receipt),
      ) &&
      sameRect(region.cropPoints, pointFrame(region.cropCells, receipt)) &&
      pixelFrameContained(region.cropPixels, receipt.pixelSize) &&
      samePixelFrame(
        region.cropPixels,
        pixelFrame(region.cropCells, receipt),
      ) &&
      region.inkPixelCount <=
        region.cropPixels.width * region.cropPixels.height,
  );
}

function regionID(frame: {
  column: number;
  row: number;
  width: number;
  height: number;
}): string {
  const part = (value: number): string => String(value).padStart(2, "0");
  return `r${part(frame.column)}-${part(frame.row)}-${part(frame.width)}-${part(frame.height)}`;
}

function pointFrame(
  frame: { column: number; row: number; width: number; height: number },
  receipt: PageVisionReceipt,
): { x: number; y: number; width: number; height: number } {
  const x = frame.column * receipt.gridSpacing;
  const y = frame.row * receipt.gridSpacing;
  const maximumX = Math.min(
    receipt.pageSize.width,
    (frame.column + frame.width) * receipt.gridSpacing,
  );
  const maximumY = Math.min(
    receipt.pageSize.height,
    (frame.row + frame.height) * receipt.gridSpacing,
  );
  return { x, y, width: maximumX - x, height: maximumY - y };
}

function pixelFrame(
  frame: { column: number; row: number; width: number; height: number },
  receipt: PageVisionReceipt,
): { x: number; y: number; width: number; height: number } {
  const x = Math.floor(
    frame.column * receipt.gridSpacing * receipt.renderScale,
  );
  const y = Math.floor(frame.row * receipt.gridSpacing * receipt.renderScale);
  const maximumX = Math.min(
    receipt.pixelSize.width,
    Math.ceil(
      (frame.column + frame.width) * receipt.gridSpacing * receipt.renderScale,
    ),
  );
  const maximumY = Math.min(
    receipt.pixelSize.height,
    Math.ceil(
      (frame.row + frame.height) * receipt.gridSpacing * receipt.renderScale,
    ),
  );
  return { x, y, width: maximumX - x, height: maximumY - y };
}

function sameRect(
  left: { x: number; y: number; width: number; height: number },
  right: { x: number; y: number; width: number; height: number },
): boolean {
  return (
    left.x === right.x &&
    left.y === right.y &&
    left.width === right.width &&
    left.height === right.height
  );
}

function samePixelFrame(
  left: { x: number; y: number; width: number; height: number },
  right: { x: number; y: number; width: number; height: number },
): boolean {
  return sameRect(left, right);
}

function cellInFrame(
  cell: { column: number; row: number },
  frame: { column: number; row: number; width: number; height: number },
): boolean {
  return (
    cell.column >= frame.column &&
    cell.column < frame.column + frame.width &&
    cell.row >= frame.row &&
    cell.row < frame.row + frame.height
  );
}

function cellFrameContained(
  frame: { column: number; row: number; width: number; height: number },
  columns: number,
  rows: number,
): boolean {
  return (
    frame.column + frame.width <= columns && frame.row + frame.height <= rows
  );
}

function rectContained(
  frame: { x: number; y: number; width: number; height: number },
  size: { width: number; height: number },
): boolean {
  return (
    frame.x + frame.width <= size.width && frame.y + frame.height <= size.height
  );
}

function pixelFrameContained(
  frame: { x: number; y: number; width: number; height: number },
  size: { width: number; height: number },
): boolean {
  return (
    frame.x + frame.width <= size.width && frame.y + frame.height <= size.height
  );
}

function publicRenderedRegions(
  receipt: PageVisionReceipt,
  regions: PageVisionRegion[],
  mode: VisionMode,
): object {
  return {
    pageID: receipt.pageID,
    drawingRevision: revision(receipt.drawingStamp),
    mode,
    appearance: mode === "ink" ? "contrast-enhanced: 2x ink-to-white difference" : "faithful paper and ink",
    images: regions.map((region, imageIndex) => ({
      imageIndex,
      regionID: region.id,
      cropCells: region.cropCells,
      cropPoints: region.cropPoints,
      cropPixels: region.cropPixels,
      pngSHA256:
        mode === "faithful" ? region.faithfulPNG_SHA256 : region.inkPNG_SHA256,
    })),
  };
}

async function resolvePage(
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
  return store.readNotebookPage(notebookID, pageNumber);
}

function findRegion(
  receipt: PageVisionReceipt,
  regionID: string,
): PageVisionRegion {
  const region = receipt.regions.find((candidate) => candidate.id === regionID);
  if (!region) {
    throw new StoreError(
      "Область больше не существует. Сначала снова вызовите notebook_page_map.",
    );
  }
  return region;
}

async function readVerifiedRegion(
  store: NotebookStore,
  receipt: PageVisionReceipt,
  region: PageVisionRegion,
  mode: VisionMode,
): Promise<Buffer> {
  const expectedSHA256 =
    mode === "faithful" ? region.faithfulPNG_SHA256 : region.inkPNG_SHA256;
  return readVerifiedPNG(
    store,
    receipt,
    {kind:"pageRegion",id:receipt.pageID,regionID:region.id,mode,expectedSHA256},
    {
      width: region.cropPixels.width,
      height: region.cropPixels.height,
    },
  );
}

async function readVerifiedPNG(
  store: NotebookStore,
  receipt: PageVisionReceipt,
  artifact: import("./store.js").ArtifactRequest,
  expectedSize: { width: number; height: number },
): Promise<Buffer> {
  let image: Buffer;
  try {
    image = await store.readArtifact(artifact);
  } catch (error) {
    if (error instanceof BridgeError && error.detail.code === "artifact_missing") {
      return rebuildPageVision(store, receipt);
    }
    throw error;
  }
  const actualSHA256 = createHash("sha256").update(image).digest("hex");
  if (actualSHA256 !== artifact.expectedSHA256) {
    return rebuildPageVision(store, receipt);
  }
  const actualSize = pngSize(image);
  if (
    !actualSize ||
    actualSize.width !== expectedSize.width ||
    actualSize.height !== expectedSize.height
  ) {
    throw new StoreError(
      "Размер изображения не совпадает с квитанцией. Повторите запрос через мгновение.",
    );
  }
  return image;
}

async function rebuildPageVision(store: NotebookStore, receipt: PageVisionReceipt): Promise<never> {
  const page = await store.readPage(receipt.pageID);
  if (revision(page.drawingStamp) !== revision(receipt.drawingStamp)) {
    throw new StoreError("Лист изменился после карты. Сначала снова вызовите notebook_page_map.");
  }
  return requestPageVision(store, page);
}

function pngSize(image: Buffer): { width: number; height: number } | null {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (
    image.length < 24 ||
    !image.subarray(0, signature.length).equals(signature) ||
    image.toString("ascii", 12, 16) !== "IHDR"
  ) {
    return null;
  }
  const width = image.readUInt32BE(16);
  const height = image.readUInt32BE(20);
  return width > 0 && height > 0 ? { width, height } : null;
}

function sameID(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase();
}

async function visionSafely(operation: () => Promise<object>): Promise<{
  content: Array<{ type: "text"; text: string }>;
  structuredContent?: object;
  isError?: boolean;
}> {
  try {
    const result = await operation();
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      structuredContent: result,
    };
  } catch (error) {
    return visionError(error);
  }
}

async function visionImageSafely(
  operation: () => Promise<{ data: object; images: string[] }>,
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
    return {
      content: [
        { type: "text", text: JSON.stringify(result.data, null, 2) },
        ...result.images.map((data) => ({
          type: "image" as const,
          data,
          mimeType: "image/png" as const,
        })),
      ],
      structuredContent: result.data,
    };
  } catch (error) {
    return visionError(error);
  }
}

function visionError(error: unknown): {
  content: Array<{ type: "text"; text: string }>;
  structuredContent: object;
  isError: true;
} {
  const message = error instanceof Error ? error.message : String(error);
  const bridgeCode = error instanceof BridgeError ? error.detail.code : undefined;
  const pending = bridgeCode === "snapshot_pending" || /собирается|создана|обновляются|обновляется/.test(message);
  const data = {
    status: pending ? "pending" : "error",
    code: bridgeCode ?? (pending ? "snapshot_pending" : "operation_failed"),
    message,
    ...(error instanceof PageVisionPending ? { requestID: error.requestID } : {}),
    retryAfterMilliseconds: pending ? 500 : null,
  };
  return {
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    structuredContent: data,
    isError: true,
  };
}
