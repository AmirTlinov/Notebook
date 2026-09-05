import { notebookResponseSchema } from "./contracts.js";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { targetSchema, referenceSchema, actionResult } from "./actions.js";
import { runBridge, BridgeError } from "./bridge.js";
import { NotebookStore } from "./store.js";

const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();
const world = z.object({ tileX: z.number().int(), tileY: z.number().int(), localX: z.number().finite(), localY: z.number().finite() }).strict();
export function registerCollaborationTools(server: McpServer, store: NotebookStore) {
  server.registerTool("notebook_point", {
    outputSchema: notebookResponseSchema,
    title: "Point to the source and share your interpretation",
    description: "Create a durable shared context from exact source references, or reply to an explicit entry in context_id. Copy the observed source revision for a considered fragment. Camera and human selection are unchanged; earlier contexts remain readable.",
    inputSchema: z.object({ context_id: z.uuid().optional(), reply_to: z.uuid().optional(),
      references: z.array(z.object({ target: targetSchema, element_id: z.string().optional(), region: frame.optional(),
        world_origin: world.optional(), page_index: z.number().int().nonnegative().optional(),
        source_revision: z.string().regex(/^[a-f0-9]{64}$/).optional(), label: z.string().max(1000).default("") }).strict()).min(1).max(32) }).strict(),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, input => actionResult(async () => {
    const references = await Promise.all(input.references.map(async value => ({ id: randomUUID(), target: value.target,
      elementID: value.element_id, region: value.region, worldOrigin: value.world_origin, pageIndex: value.page_index,
      label: value.label, revision: value.source_revision ?? (await runBridge<{revision:string}>(store.root,
        {command:"reference",target:value.target,elementID:value.element_id})).revision })));
    return { status: "saved", context: await runBridge(store.root, {command:"point",references,
      contextID:input.context_id,replyTo:input.reply_to}) };
  }));
  server.registerTool("notebook_render", {
    outputSchema: notebookResponseSchema,
    title: "See a complete surface independently of the camera",
    description: "Request paper, final Pencil pixels and agent content for an explicit owner. A region crops local points; board world_origin anchors its region. Document page_index starts at 0. Returns exact source versions, PNG hash and runtime diagnostics. Pending is a useful state; wait_ms is bounded to four seconds. Camera remains human-owned.",
    inputSchema: z.object({ target: targetSchema, expected_revision: z.string(), region: frame.optional(), world_origin: world.optional(), page_index: z.number().int().nonnegative().default(0), wait_ms: z.number().int().min(0).max(4000).default(0) }).strict(),
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async input => {
    let png: Buffer | undefined;
    const result = await actionResult(async () => {
      const request = await runBridge<{ id: string; sourceRevision: string }>(store.root, { command: "render", target: input.target,
        expectedRevision: input.expected_revision, region: input.region, worldOrigin: input.world_origin, pageIndex: input.page_index });
      const path = join(store.root, "previews", "targets", request.id.toLowerCase());
      const deadline = Date.now() + input.wait_ms;
      do {
        const receipt = await readFile(path + ".json", "utf8").then(JSON.parse).catch(() => null);
        if (receipt?.request.sourceRevision === request.sourceRevision) {
          if (receipt.status === "ready") {
            const current = await runBridge<{revision:string}>(store.root, {command:"reference",target:input.target});
            if (current.revision !== request.sourceRevision) throw new BridgeError({code:"revision_conflict",message:"Содержимое изменилось во время подготовки снимка."});
            png = await readFile(path + ".png");
            if (createHash("sha256").update(png).digest("hex") !== receipt.pngSHA256) throw new BridgeError({code:"snapshot_pending",message:"PNG догоняет квитанцию."});
          }
          return receipt;
        }
        if (Date.now() >= deadline) break;
        await new Promise(resolve => setTimeout(resolve, Math.min(100, deadline - Date.now())));
      } while (Date.now() <= deadline);
      return { status: "pending", code: "snapshot_pending", request };
    });
    return png ? { ...result, content: [...result.content, { type: "image" as const, data: png.toString("base64"), mimeType: "image/png" }] } : result;
  });
  server.registerTool("notebook_place", {
    outputSchema: notebookResponseSchema,
    title: "Find room beside the thought",
    description: "Calculate one complete composition without writing content. Items have unique IDs, sizes and an existing source or preceding item as anchor. Fixed objects and final ink remain obstacles. Only explicitly movable subjects in context_id or additional_owners may be rearranged, and only if the package cannot fit otherwise. Return placements, necessary moves and exact expected versions for notebook_apply. A full surface returns placement_unavailable for the whole package; snapshot_pending never means empty paper.",
    inputSchema: z.object({ target: targetSchema, expected_revision: z.string(), context_id: z.uuid().optional(),
      additional_owners: z.array(targetSchema).max(32).default([]), world_origin: world.optional(),
      items: z.array(z.object({ id: z.string().min(1).max(120), size: z.object({width:z.number().positive().max(2048),height:z.number().positive().max(2048)}).strict(),
        relative_to: referenceSchema.optional(), relative_to_id: z.string().min(1).max(120).optional(), direction: z.enum(["right","below","free"]).default("free") }).strict()).min(1).max(32),
      movable: z.array(z.object({target:targetSchema,element_id:z.string().min(1).max(120).optional()}).strict()).max(32).default([]) }).strict(),
    annotations: {readOnlyHint:true,openWorldHint:false},
  }, input => actionResult(() => runBridge(store.root,{command:"placement",placement:{ target:input.target,expectedRevision:input.expected_revision,
    contextID:input.context_id,additionalOwners:input.additional_owners,worldOrigin:input.world_origin,
    items:input.items.map(item=>({id:item.id,size:item.size,relativeTo:item.relative_to,relativeToID:item.relative_to_id,direction:item.direction})),
    movable:input.movable.map(subject=>({target:subject.target,elementID:subject.element_id})) }})));

  server.registerTool("notebook_search", {
    outputSchema: notebookResponseSchema,
    title: "Find a thought across the whole board tree",
    description: "Search titles, document blocks and agent text on pages, boards and covers. Each result includes its physical path and a stable reference. Handwriting is available through notebook_page_map and images.",
    inputSchema: z.object({ query: z.string().trim().min(1).max(500), limit: z.number().int().min(1).max(100).default(20) }).strict(),
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ query, limit }) => actionResult(() => runBridge(store.root, {command:"search",query,limit})));
}
