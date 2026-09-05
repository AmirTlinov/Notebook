import { notebookResponseSchema } from "./contracts.js";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/server";
import { marked } from "marked";
import * as z from "zod/v4";
import { runBridge, BridgeError } from "./bridge.js";
import { NotebookStore } from "./store.js";

export const targetSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("page"), id: z.uuid() }).strict(),
  z.object({ kind: z.literal("document"), id: z.uuid() }).strict(),
  z.object({ kind: z.literal("board"), id: z.uuid() }).strict(),
  z.object({ kind: z.literal("cover"), id: z.uuid(), boardID: z.uuid() }).strict(),
  z.object({ kind: z.literal("workspace"), id: z.uuid().describe("rootBoardID") }).strict(),
]);
export type Target = z.infer<typeof targetSchema>;
const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();
const point = z.object({ tileX: z.number().int(), tileY: z.number().int(), localX: z.number().finite(), localY: z.number().finite() }).strict();
export const referenceSchema = z.object({ id: z.uuid(), target: targetSchema, elementID: z.string().optional(), region: frame.optional(), worldOrigin: point.optional(), pageIndex: z.number().int().nonnegative().optional(), revision: z.string(), label: z.string().max(1000).default("") }).strict();
const expectation = z.object({ target: targetSchema, revision: z.string().min(1), stateRevision:z.string().optional(), sourceRevision:z.string().optional() }).strict();
const source = z.string().max(1_000_000);
const block = z.discriminatedUnion("kind", [
  z.object({ id: z.string().min(1).max(120), kind: z.enum(["markdown", "latex"]), source }).strict(),
  z.object({ id: z.string().min(1).max(120), kind: z.literal("interactive"), html: source,
    css: source.optional(), javaScript: source.optional(), initialState: z.json().optional(), height: z.number().min(48).max(2048).optional() }).strict(),
]);
const editFields = z.object({ source: source.optional(), html: source.optional(), css: source.optional(), javaScript: source.optional(),
  frame: frame.optional(), worldOrigin: point.optional() }).strict();
const op = <K extends string, S extends z.ZodType>(kind: K, values: S, id: z.ZodType | null = z.string().min(1).max(120)) =>
  z.object({ kind: z.literal(kind), target: targetSchema, ...(id ? { id } : {}), values }).strict();
export const operationSchema = z.discriminatedUnion("kind", [
  op("insertElement", z.object({ kind: z.enum(["markdown", "web"]), source, frame,
    html: source.optional(), css: source.optional(), javaScript: source.optional(), state: z.json().optional(), worldOrigin: point.optional() }).strict()),
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
  op("renameItem", z.object({ title: z.string().max(240) }).strict(), z.uuid()),
  op("moveItem", z.object({ center: point }).strict(), z.uuid()),
  op("stackItems", z.object({ itemIDs: z.array(z.uuid()).min(2).max(5) }).strict(), null),
]);
export const actionSchema = z.object({ action_id: z.uuid(), context_id: z.uuid().optional(), summary: z.string().min(1).max(1000),
  references: z.array(referenceSchema).max(32).default([]), expected: z.array(expectation).min(1).max(1024),
  operations: z.array(operationSchema).min(1).max(512) }).strict();

export interface ActionReceipt {
  id: string;
  action: { contextID?: string; summary: string; references: unknown[]; operations: Array<{ kind: string; target: Target; id?: string; values: Record<string, unknown> }> };
  revisions: Array<{ target: Target; revision: string }>;
  createdAt: number;
  undo?: { restored: number; preserved: unknown[]; completedAt: number };
  changes: unknown[];
}

export function registerActionTools(server: McpServer, store: NotebookStore): void {
  const outputSchema = notebookResponseSchema;
  server.registerTool("notebook_apply", {
    title: "Continue one shared thought",
    description: "Apply one named, atomic, undoable action to explicit owners. Read their revisions first. Omitted update fields retain their values; interactive state has a separate operation. Creation keeps the human's camera and selection. Reuse action_id only for the same action. Workspace expectations use rootBoardID and workspaceRevision; page expectations use agentRevision; documents contentRevision; boards boardRevision.",
    inputSchema: actionSchema, outputSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  }, (input) => actionResult(async () => {
    const prepared = await prepareAction(input, store);
    const receipt = await runBridge<ActionReceipt>(store.root, { command: "apply", action: prepared });
    return publicAction(receipt, store);
  }));
  server.registerTool("notebook_undo", {
    title: "Undo one agent action while keeping human edits",
    description: "Restore fields still owned by the action. Later human changes remain and are listed as preserved. Repeating undo returns its existing result.",
    inputSchema: z.object({ action_id: z.uuid() }).strict(), outputSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  }, ({ action_id }) => actionResult(async () => publicAction(await runBridge<ActionReceipt>(store.root, { command: "undo", actionID: action_id }), store)));
  server.registerTool("notebook_action", {
    title: "Read an action and its exact publication state",
    description: "Read one action by ID, or the latest actions. The saved result and device display confirmation are distinct facts.",
    inputSchema: z.object({ action_id: z.uuid().optional(), limit: z.number().int().min(1).max(50).default(10) }).strict(), outputSchema,
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ action_id, limit }) => actionResult(async () => action_id
    ? publicAction(await runBridge<ActionReceipt>(store.root, { command: "action", actionID: action_id }), store)
    : { status: "ready", actions: await Promise.all((await runBridge<ActionReceipt[]>(store.root, { command: "actions" })).slice(0, limit).map(receipt => publicAction(receipt, store))) }));
}

export async function publicAction(receipt: ActionReceipt, store: NotebookStore): Promise<Record<string, unknown>> {
  const continuations = await runBridge(store.root,{command:"continuations",actionID:receipt.id});
  const delivery = await runBridge<Array<{id:string;revisions:unknown[];shown:Array<{target:Target;revision:string}>;displayComplete:boolean;visibleRegions:unknown[]}>>(store.root,{command:"delivery"});
  const device = delivery.find(value => value.id.toLowerCase() === receipt.id.toLowerCase());
  const same = (a:unknown,b:unknown) => JSON.stringify(a) === JSON.stringify(b);
  const received = device && same(device.revisions,receipt.revisions);
  const shown = received && device.displayComplete;
  const directory = join(store.root,"previews","targets");
  const names = await readdir(directory).catch(()=>[]);
  const snapshots = (await Promise.all(names.filter(name=>name.endsWith(".json")).map(name => readFile(join(directory,name),"utf8").then(JSON.parse).catch(()=>null))))
    .filter(value => value?.status === "ready" && receipt.revisions.some(r => r.target.id.toLowerCase() === value.request.target.id.toLowerCase() && r.target.kind === value.request.target.kind))
    .map(value => ({target:value.request.target,sourceRevision:value.request.sourceRevision,region:value.request.region ?? null,pageIndex:value.request.pageIndex,pngSHA256:value.pngSHA256,diagnostics:value.diagnostics}));
  return { status: "saved", action: {id:receipt.id,contextID:receipt.action.contextID ?? receipt.id,summary:receipt.action.summary,references:receipt.action.references,
    createdAt:receipt.createdAt,revisions:receipt.revisions,continuations,results:receipt.action.operations.map(({kind,target,id,values})=>({kind,target,id,frame:values.frame})),
    ...(receipt.undo ? {undo:{...receipt.undo,preserved:receipt.undo.preserved.map(value=>{const field=value as {file:string;path:unknown};return {file:field.file,path:field.path};})}} : {})},
    publication: {saved:{status:"confirmed"},receivedByIPad:{status:received?"confirmed":"awaiting_device"},
      snapshots,shownOnIPad:{status:shown?"confirmed":"awaiting_display",visibleRegions:received?device.visibleRegions:[]}} };
}

function deterministicID(actionID: string, suffix: string): string {
  const hex = createHash("sha256").update(`${actionID.toLowerCase()}:${suffix}`).digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

async function prepareAction(input: z.infer<typeof actionSchema>, store: NotebookStore): Promise<object> {
  const operations: Array<Record<string, unknown>> = [];
  const kinds = new Map<string, string>();
  for (const [index, original] of input.operations.entries()) {
    const operation = structuredClone(original) as { kind: string; target: Target; id?: string; values: Record<string, unknown> };
    if (operation.kind.startsWith("create")) {
      operation.id ??= deterministicID(input.action_id, `item:${index}`);
      if (operation.kind === "createNotebook") operation.values.pageID ??= deterministicID(input.action_id, `page:${index}`);
    }
    const key = `${operation.target.kind}:${operation.target.id}:${operation.id}`;
    if (operation.kind === "insertElement") kinds.set(key, String(operation.values.kind));
    if (operation.kind === "updateElement" && typeof operation.values.source === "string") {
      if (!kinds.has(key)) {
        const elements = operation.target.kind === "page"
          ? (await store.readPage(operation.target.id)).elements
          : (await store.readBoard(undefined, operation.target.kind === "cover" ? operation.target.boardID : operation.target.id)).elements;
        kinds.set(key, elements.find(e => e.id === operation.id)?.kind ?? "");
      }
    }
    if (kinds.get(key) === "markdown" && typeof operation.values.source === "string") {
      operation.values.html = await marked.parse(operation.values.source, { async: true, gfm: true });
    }
    if (typeof operation.values.javaScript === "string") {
      try { Function(operation.values.javaScript); } catch (error) {
        throw new BridgeError({ code: "invalid_javascript", message: String(error) });
      }
    }
    operations.push(operation);
  }
  return { id: input.action_id, contextID: input.context_id, summary: input.summary, references: input.references, expected: input.expected, operations };
}

export async function actionResult(operation: () => Promise<Record<string, unknown>>) {
  try {
    const data = await operation();
    return { content: [{ type: "text" as const, text: JSON.stringify(data) }], structuredContent: data };
  } catch (error) {
    const data = error instanceof BridgeError ? { status: "error", ...error.detail }
      : { status: "error", code: "operation_failed", message: String(error) };
    return { content: [{ type: "text" as const, text: JSON.stringify(data) }], structuredContent: data, isError: true };
  }
}
