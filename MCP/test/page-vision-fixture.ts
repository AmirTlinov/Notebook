import * as z from "zod/v4";
// Test fixture wire shape; native Core validates production receipts.
const maximumPageDimension = 2_048;
const maximumRenderScale = 16;
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
