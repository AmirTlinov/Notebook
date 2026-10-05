import { worldPointSchema as point } from "./spatial.js";
import * as z from "zod/v4";

const uuid=z.uuid();

const boardTarget = z.object({ kind: z.literal("board"), id: uuid }).strict();
export const coverTargetSchema = z.object({ kind: z.literal("cover"), id: uuid, boardID: uuid }).strict();
export const targetSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("codeFragment"), id: uuid }).strict(),
  z.object({ kind: z.literal("page"), id: uuid }).strict(),
  z.object({ kind: z.literal("document"), id: uuid }).strict(),
  boardTarget,
  coverTargetSchema,
  z.object({ kind: z.literal("workspace"), id: uuid.describe("rootBoardID") }).strict(),
]);
export type Target = z.infer<typeof targetSchema>;
const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();

export const referenceSchema = z.object({ id: uuid, target: targetSchema, elementID: z.string().optional(), region: frame.optional(), worldOrigin: point.optional(), pageIndex: z.number().int().nonnegative().optional(), revision: z.string(), label: z.string().max(1000).default("") }).strict();
export const expectationSchema = z.object({ target: targetSchema, revision: z.string().min(1), stateRevision:z.string().optional(), sourceRevision:z.string().optional(), lifecycleRevision:z.string().regex(/^[a-f0-9]{64}$/).optional().describe("Complete item extent from an explicit itemLifecycle read; covers off-screen content and is not mutation authority."), inkRevision:z.string().optional().describe("For appendInkStroke: drawingRevision of a page, spatialInkRevision of a board/cover, or inkRevision returned by nb.code.") }).strict();
const source = z.string().max(1_000_000);
const programPackage = z.string().regex(/^[a-f0-9]{64}$/).nullable().describe("Immutable staged package SHA; requires empty inline source/html/css/javaScript. Null switches back to inline.");
export const textStyleSchema = z.object({fontSize:z.number().min(3).max(5760),weight:z.number().min(0).max(1),
  red:z.number().min(0).max(1),green:z.number().min(0).max(1),blue:z.number().min(0).max(1),alpha:z.number().min(0).max(1)}).strict();
export const documentPathSchema = z.string().min(1).max(512).regex(/^(?!\/)(?!.*(?:^|\/)\.\.?(?:\/|$))[A-Za-z0-9@_.-]+(?:\/[A-Za-z0-9@_.-]+)*$/);
export const documentSourceSchema = z.string().max(4 * 1024 * 1024);
export const contentFieldVersionSchema = z.object({
  stamp:z.object({counter:z.number().int().nonnegative(),actor:uuid}).strict(),
  human:z.boolean(),observed:z.record(z.string(),z.number().int().nonnegative()),
}).strict();
export const documentResourceSchema = z.object({path:documentPathSchema,mimeType:z.string().min(1),
  byteCount:z.number().int().nonnegative(),parts:z.array(z.object({sha256:z.string().regex(/^[a-f0-9]{64}$/),
    byteCount:z.number().int().min(1).max(4*1024*1024)}).strict()).max(16384)}).strict();
export const documentFileSchema = z.object({id:z.string().min(1).max(120),path:documentPathSchema,
  source:documentSourceSchema,resource:documentResourceSchema.optional()}).strict();
const graphicColor = z.object({ red: z.number().min(0).max(1), green: z.number().min(0).max(1), blue: z.number().min(0).max(1) }).strict();
const graphicStyle = z.object({ stroke: graphicColor, strokeWidth: z.number().positive().max(1_000_000), fill: graphicColor.optional(), dash: z.enum(["solid", "dashed", "dotted"]).optional() }).strict();
const graphicScalar = z.number().finite().min(-1e6).max(1e6);
const graphicPoint = z.object({ x: graphicScalar, y: graphicScalar }).strict();
const graphicBinding = z.object({ elementID: z.string().min(1).max(120),
  normalizedAnchor: z.object({x:z.number().min(0).max(1), y:z.number().min(0).max(1)}).strict(),
  isExact: z.boolean(), isPrecise: z.boolean() }).strict();
const graphicEndpoint = z.object({point: graphicPoint, binding: graphicBinding.optional()}).strict();
const arrowhead = z.enum(["none", "arrow", "triangle", "square", "dot", "pipe", "diamond", "inverted", "bar"]);
const graphicConnection = z.object({start:graphicEndpoint, end:graphicEndpoint,
  bend:graphicScalar, startArrowhead:arrowhead, endArrowhead:arrowhead,
  routing:z.enum(["straight","elbow","curved"]).optional(), elbowAxis:z.enum(["horizontal","vertical"]).optional(),
  labelPosition:z.number().min(0).max(1), bendPosition:graphicScalar.optional()}).strict();
const graphicTransform = z.object({a:z.number().finite(),b:z.number().finite(),c:z.number().finite(),d:z.number().finite(),tx:z.number().finite(),ty:z.number().finite()}).strict();
const inkVertex = graphicPoint.extend({opacity:z.number().min(0).max(1)}).strict();
const compactEraser = z.object({size:z.object({x:z.number().finite().positive().max(1e6),y:z.number().finite().positive().max(1e6)}).strict(),
  samples:z.array(z.object({point:graphicPoint,width:z.number().finite().positive().max(1e6)}).strict()).min(1).max(100000)}).strict();
// Exact NIM1 body is opaque to the JS adapter; the Core codec validates its graph.
const measuredInk = z.object({sourceID:uuid,span:z.number().int().min(0).max(1e6),
  measurements:z.base64().min(8).max(24*1024*1024),
  frame:frame.extend({width:z.number().finite().positive().max(1e6),height:z.number().finite().positive().max(1e6)}),
  origin:point.optional()}).strict();
const freehand = z.object({layers:z.array(z.union([
  z.object({tool:z.enum(["pen","eraser"]),color:graphicColor,vertices:z.array(inkVertex).min(3).max(65536)}).strict(),
  z.object({tool:z.literal("eraser"),color:graphicColor,vertices:z.array(inkVertex).length(0),eraser:compactEraser}).strict(),
  z.object({tool:z.enum(["pen","eraser"]),color:graphicColor,vertices:z.array(inkVertex).length(0),measured:measuredInk}).strict()
])).min(1).max(2048)}).strict();
export const graphicSchema = z.object({ shape: z.enum(["ellipse", "rectangle", "triangle", "diamond", "plus", "connector", "freehand", "path"]), style: graphicStyle, label: z.string().max(100_000),
  representation: z.enum(["ink", "geometry"]), visible: z.boolean(), sourceInkIDs: z.array(uuid).max(1024), connection:graphicConnection.optional(),
  path:z.object({commands:z.array(z.object({kind:z.enum(["move","line","quad","curve","close"]),points:z.array(graphicPoint).max(3)}).strict()).min(1).max(8192)}).strict().nullable().optional(),
  transform:graphicTransform.nullable().optional(),freehand:freehand.nullable().optional(),
  cornerRadius:z.number().finite().min(0).max(1e6).nullable().optional(),
  vertices:z.array(z.object({x:z.number().min(0).max(1),y:z.number().min(0).max(1)}).strict()).min(3).max(4).nullable().optional() }).strict();
const graphicEdit = graphicSchema.omit({ sourceInkIDs: true, connection: true }).partial().extend({connection:graphicConnection.partial().strict().optional()}).strict();
const editFields = z.object({ source: source.optional(), html: source.optional(), css: source.optional(), javaScript: source.optional(), programPackage: programPackage.optional(),
  graphic: graphicEdit.optional(), frame: frame.optional(), worldOrigin: point.optional(), textStyle: textStyleSchema.optional() }).strict();
const op = <K extends string, S extends z.ZodType>(kind: K, values: S, id: z.ZodType | null = z.string().min(1).max(120)) =>
  z.object({ kind: z.literal(kind), target: targetSchema, ...(id ? { id } : {}), values }).strict();
export const inkStrokePointSchema=z.object({x:z.number().finite().min(-1e6).max(1e6),y:z.number().finite().min(-1e6).max(1e6),
  width:z.number().positive().max(128).optional(),opacity:z.number().min(0).max(1).optional(),
  timeOffset:z.number().finite().nonnegative().optional(),force:z.number().finite().nonnegative().optional(),
  azimuth:z.number().finite().optional(),altitude:z.number().finite().optional()}).strict();
export const appendInkStrokeSchema=op("appendInkStroke",z.object({
    points: z.array(inkStrokePointSchema).min(1).max(8192)
      .describe("Ordered native pen samples in owner-local points; per-point width/opacity override the stroke defaults."),
    width: z.number().positive().max(128).optional().describe("Pen width in physical points; defaults to 2."),
    opacity: z.number().min(0).max(1).optional().describe("Defaults to 1; matches native ink opacity."),
    color: z.object({ red: z.number().min(0).max(1), green: z.number().min(0).max(1), blue: z.number().min(0).max(1) }).strict().optional(),
    worldOrigin: point.optional().describe("Required for board ink: points are offsets from this tiled origin. Omit on pages/covers."),
  }).strict(),uuid.optional());
export const operationSchema = z.discriminatedUnion("kind", [
  appendInkStrokeSchema,
  op("insertElement", z.object({ kind: z.enum(["markdown", "web", "nativeText", "graphic"]), source, frame, graphic: graphicSchema.optional(),
    html: source.optional(), css: source.optional(), javaScript: source.optional(), programPackage: programPackage.optional(), state: z.json().optional(), worldOrigin: point.optional(), textStyle: textStyleSchema.optional() }).strict()),
  op("convertInkToElement", z.object({ kind: z.literal("graphic"), source, frame, graphic: graphicSchema, worldOrigin: point.optional() }).strict()),
  op("updateElement", editFields),
  op("setElementState", z.object({ state: z.json() }).strict()),
  op("removeElement", z.object({}).strict().default({})),
  op("reorderElements", z.object({ ids: z.array(z.string()).max(512) }).strict(), null),
  op("putDocumentFile", z.object({path:documentPathSchema,source:documentSourceSchema.optional(),
    resource:documentResourceSchema.optional(),expectedVersion:contentFieldVersionSchema.nullable()}).strict()),
  op("patchDocumentFile", z.object({expectedVersion:contentFieldVersionSchema,
    range:z.object({location:z.number().int().nonnegative(),length:z.number().int().nonnegative()}).strict(),
    expectedText:documentSourceSchema,source:documentSourceSchema}).strict()),
  op("renameDocumentFile", z.object({expectedVersion:contentFieldVersionSchema,path:documentPathSchema}).strict()),
  op("removeDocumentFile", z.object({expectedVersion:contentFieldVersionSchema}).strict()),
  op("setDocumentProgramState", z.object({programPath:documentPathSchema,sourceBasis:z.string().min(1),state:z.json()}).strict()),
  op("createNotebook", z.object({ title: z.string().max(240).optional(), center: point, pageID: uuid.optional() }).strict(), uuid.optional()),
  op("createDocument", z.object({title:z.string().max(240).optional(),center:point,entrypoint:documentPathSchema.optional(),template:z.enum(["article","report","contract","instruction","book"]).optional(),files:z.array(documentFileSchema).max(4096).optional()}).strict(), uuid.optional()),
  op("createBoard", z.object({ title: z.string().max(240).optional(), center: point }).strict(), uuid.optional()),
  op("appendPage", z.object({}).strict(), uuid.optional()).extend({target:coverTargetSchema}),
  op("deleteItem", z.object({}).strict(), null).extend({target:coverTargetSchema}),
  op("renameItem", z.object({ title: z.string().max(240) }).strict(), uuid).extend({
    target: boardTarget.describe("The board currently containing this item, as read({kind:'ownerBoard',id:itemID}) returns. Workspace is an expectation owner, not this operation's target."),
  }),
  op("moveItem", z.object({ center: point }).strict(), uuid),
  op("stackItems", z.object({ itemIDs: z.array(uuid).min(2).max(5) }).strict(), null),
]);
export const actionSchema = z.object({ contextID: uuid.optional(), additionalOwners: z.array(targetSchema).max(32).optional(), summary: z.string().min(1).max(1000),
  references: z.array(referenceSchema).max(32).default([]), expected: z.array(expectationSchema).min(1).max(1024),
  operations: z.array(operationSchema).min(1).max(512) }).strict();
