import { worldPointSchema as point } from "./spatial.js";
import * as z from "zod/v4";

const boardTarget = z.object({ kind: z.literal("board"), id: z.uuid() }).strict();
export const coverTargetSchema = z.object({ kind: z.literal("cover"), id: z.uuid(), boardID: z.uuid() }).strict();
export const targetSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("codeFragment"), id: z.uuid() }).strict(),
  z.object({ kind: z.literal("page"), id: z.uuid() }).strict(),
  z.object({ kind: z.literal("document"), id: z.uuid() }).strict(),
  boardTarget,
  coverTargetSchema,
  z.object({ kind: z.literal("workspace"), id: z.uuid().describe("rootBoardID") }).strict(),
]);
export type Target = z.infer<typeof targetSchema>;
const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();

export const referenceSchema = z.object({ id: z.uuid(), target: targetSchema, elementID: z.string().optional(), region: frame.optional(), worldOrigin: point.optional(), pageIndex: z.number().int().nonnegative().optional(), revision: z.string(), label: z.string().max(1000).default("") }).strict();
export const expectationSchema = z.object({ target: targetSchema, revision: z.string().min(1), stateRevision:z.string().optional(), sourceRevision:z.string().optional(), lifecycleRevision:z.string().regex(/^[a-f0-9]{64}$/).optional().describe("Complete item extent from an explicit itemLifecycle read; covers off-screen content and is not mutation authority."), inkRevision:z.string().optional().describe("For appendInkStroke: drawingRevision of a page, spatialInkRevision of a board/cover, or inkRevision returned by nb.code.") }).strict();
const source = z.string().max(1_000_000);
const textStyle = z.object({fontSize:z.number().min(8).max(240),weight:z.number().min(0).max(1),
  red:z.number().min(0).max(1),green:z.number().min(0).max(1),blue:z.number().min(0).max(1),alpha:z.number().min(0).max(1)}).strict();
const block = z.discriminatedUnion("kind", [
  z.object({ id: z.string().min(1).max(120), kind: z.enum(["markdown", "latex"]), source }).strict(),
  z.object({ id: z.string().min(1).max(120), kind: z.literal("interactive"), html: source,
    css: source.optional(), javaScript: source.optional(), initialState: z.json().optional(), height: z.number().min(48).max(2048).optional() }).strict(),
]);
const graphicColor = z.object({ red: z.number().min(0).max(1), green: z.number().min(0).max(1), blue: z.number().min(0).max(1) }).strict();
const graphicStyle = z.object({ stroke: graphicColor, strokeWidth: z.number().positive().max(1_000_000), fill: graphicColor.optional(), dash: z.enum(["solid", "dashed", "dotted"]).optional() }).strict();
const graphicPoint = z.object({ x: z.number().finite().min(-1e6).max(1e6), y: z.number().finite().min(-1e6).max(1e6) }).strict();
const graphicBinding = z.object({ elementID: z.string().min(1).max(120),
  normalizedAnchor: z.object({x:z.number().min(0).max(1), y:z.number().min(0).max(1)}).strict(),
  isExact: z.boolean(), isPrecise: z.boolean() }).strict();
const graphicEndpoint = z.object({point: graphicPoint, binding: graphicBinding.optional()}).strict();
const arrowhead = z.enum(["none", "arrow", "triangle", "square", "dot", "pipe", "diamond", "inverted", "bar"]);
const graphicConnection = z.object({start:graphicEndpoint, end:graphicEndpoint,
  bend:z.number().finite().min(-1e6).max(1e6), startArrowhead:arrowhead, endArrowhead:arrowhead,
  routing:z.enum(["straight","elbow","curved"]).optional(),
  labelPosition:z.number().min(0).max(1), bendPosition:z.number().min(0).max(1).optional()}).strict();
export const graphicSchema = z.object({ shape: z.enum(["ellipse", "rectangle", "triangle", "diamond", "plus", "connector"]), style: graphicStyle, label: z.string().max(100_000),
  representation: z.enum(["ink", "geometry"]), visible: z.boolean(), sourceInkIDs: z.array(z.uuid()).max(16), connection:graphicConnection.optional(),
  cornerRadius:z.number().finite().min(0).max(1e6).nullable().optional(),
  vertices:z.array(z.object({x:z.number().min(0).max(1),y:z.number().min(0).max(1)}).strict()).min(3).max(4).nullable().optional() }).strict();
const graphicEdit = graphicSchema.omit({ sourceInkIDs: true, connection: true }).partial().extend({connection:graphicConnection.partial().strict().optional()}).strict();
const editFields = z.object({ source: source.optional(), html: source.optional(), css: source.optional(), javaScript: source.optional(),
  graphic: graphicEdit.optional(), frame: frame.optional(), worldOrigin: point.optional(), textStyle: textStyle.optional() }).strict();
const op = <K extends string, S extends z.ZodType>(kind: K, values: S, id: z.ZodType | null = z.string().min(1).max(120)) =>
  z.object({ kind: z.literal(kind), target: targetSchema, ...(id ? { id } : {}), values }).strict();
export const operationSchema = z.discriminatedUnion("kind", [
  op("appendInkStroke", z.object({
    points: z.array(z.object({ x: z.number().finite().min(-1e6).max(1e6), y: z.number().finite().min(-1e6).max(1e6),
      width: z.number().positive().max(128).optional(), opacity: z.number().min(0).max(1).optional() }).strict()).min(1).max(8192)
      .describe("Ordered native pen samples in owner-local points; per-point width/opacity override the stroke defaults."),
    width: z.number().positive().max(128).optional().describe("Pen width in physical points; defaults to 2."),
    opacity: z.number().min(0).max(1).optional().describe("Defaults to 1; matches native ink opacity."),
    color: z.object({ red: z.number().min(0).max(1), green: z.number().min(0).max(1), blue: z.number().min(0).max(1) }).strict().optional(),
    worldOrigin: point.optional().describe("Required for board ink: points are offsets from this tiled origin. Omit on pages/covers."),
  }).strict(), z.uuid().optional()),
  op("insertElement", z.object({ kind: z.enum(["markdown", "web", "nativeText", "graphic"]), source, frame, graphic: graphicSchema.optional(),
    html: source.optional(), css: source.optional(), javaScript: source.optional(), state: z.json().optional(), worldOrigin: point.optional(), textStyle: textStyle.optional() }).strict()),
  op("convertInkToElement", z.object({ kind: z.literal("graphic"), source, frame, graphic: graphicSchema, worldOrigin: point.optional() }).strict()),
  op("updateElement", editFields),
  op("setElementState", z.object({ state: z.json() }).strict()),
  op("removeElement", z.object({}).strict().default({})),
  op("reorderElements", z.object({ ids: z.array(z.string()).max(512) }).strict(), null),
  op("insertBlock", z.object({ kind: z.enum(["markdown", "latex", "interactive"]), source: source.optional(), html: source.optional(), css: source.optional(),
    javaScript: source.optional(), initialState: z.json().optional(), height: z.number().min(48).max(2048).optional(), afterID: z.string().optional() }).strict()),
  op("updateBlock", z.object({ source: source.optional(), html: source.optional(), css: source.optional(), javaScript: source.optional(), height: z.number().min(48).max(2048).optional() }).strict()),
  op("setBlockState", z.object({state:z.json()}).strict()),
  op("removeBlock", z.object({}).strict().default({})),
  op("reorderBlocks", z.object({ ids: z.array(z.string()).max(512) }).strict(), null),
  op("setPreamble", z.object({ preamble: source }).strict(), null),
  op("replaceDocument", z.object({ preamble: source, blocks: z.array(block).max(512) }).strict(), null),
  op("createNotebook", z.object({ title: z.string().max(240).optional(), center: point, pageID: z.uuid().optional() }).strict(), z.uuid().optional()),
  op("createDocument", z.object({ title: z.string().max(240).optional(), center: point, paperSize: z.enum(["a4", "letter"]), preamble: source.optional(), blocks: z.array(block).max(512) }).strict(), z.uuid().optional()),
  op("createBoard", z.object({ title: z.string().max(240).optional(), center: point }).strict(), z.uuid().optional()),
  op("renameItem", z.object({ title: z.string().max(240) }).strict(), z.uuid()).extend({
    target: boardTarget.describe("The board currently containing this item, as read({kind:'ownerBoard',id:itemID}) returns. Workspace is an expectation owner, not this operation's target."),
  }),
  op("moveItem", z.object({ center: point }).strict(), z.uuid()),
  op("stackItems", z.object({ itemIDs: z.array(z.uuid()).min(2).max(5) }).strict(), null),
]);
export const actionSchema = z.object({ contextID: z.uuid().optional(), additionalOwners: z.array(targetSchema).max(32).optional(), summary: z.string().min(1).max(1000),
  references: z.array(referenceSchema).max(32).default([]), expected: z.array(expectationSchema).min(1).max(1024),
  operations: z.array(operationSchema).min(1).max(512) }).strict();
