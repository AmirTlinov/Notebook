import { worldPointSchema as world } from "./spatial.js";
import { notebookResponseSchema } from "./contracts.js";
import { createHash, randomUUID } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { targetSchema, referenceSchema, actionResult } from "./actions.js";
import { runBridge, BridgeError } from "./bridge.js";
import { revision, type VersionStamp } from "./domain.js";
import { NotebookStore } from "./store.js";

const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();

export function registerCollaborationTools(server: McpServer, store: NotebookStore) {
  server.registerTool("notebook_read_code_notes", {
    outputSchema: notebookResponseSchema,
    title: "Read preserved code and shared handwriting",
    description: "Read an immutable code fragment and its actual native ink, or list up to 64 review fragments belonging to an exact computer/project/file. Files with identical paths on different computers remain distinct. To appendInkStroke use target {kind:codeFragment,id:fragment.id}, expected.revision=revision and expected.inkRevision=inkRevision from the returned value. Coordinates belong to the preserved fragment, not to a screen or board camera.",
    inputSchema: z.discriminatedUnion("read", [
      z.object({read:z.literal("fragment"),fragment_id:z.uuid()}).strict(),
      z.object({read:z.literal("file"),file:z.object({computer:z.uuid(),project:z.string().min(1),root:z.string().min(1),path:z.string().min(1)}).strict(),after_id:z.uuid().optional()}).strict(),
    ]),
    annotations: {readOnlyHint:true,openWorldHint:false},
  }, input => actionResult(async () => {
    if (input.read === "file") return {fragments:await store.read({kind:"codeFragments",file:input.file,after:input.after_id,limit:64})};
    const value = await store.read<{fragment:{stamp:VersionStamp};ink:{stamp:VersionStamp}} | null>({kind:"codeFragment",id:input.fragment_id});
    if (!value) throw new BridgeError({code:"target_missing",message:"The preserved code fragment does not exist."});
    return {...value,revision:revision(value.fragment.stamp),inkRevision:revision(value.ink.stamp),link:"notebook://code/"+input.fragment_id.toLowerCase()};
  }));
  server.registerTool("notebook_read_attention", {
    outputSchema: notebookResponseSchema,
    title: "Read the frozen source the person pointed at",
    description: "Read an immutable human indication by context_id and reference_id from Notebook chat. The pixels and reference version do not follow the camera or later ink. This is attention, not a restriction on other Notebook tools. Unavailable pixels are explicit, not replaced by the latest surface.",
    inputSchema: z.object({ context_id: z.uuid(), reference_id: z.uuid() }).strict(),
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async input => {
    let png: string | undefined;
    const result = await actionResult(async () => {
      type Source = { id:string; requestID:string; reference:unknown; payload:unknown;
        image?: { png:string; sha256:string; pixelWidth:number; pixelHeight:number } };
      const response = await runBridge<{ values: Array<Source | null> }>(store.socketPath, {command:"read", queries:[
        {kind:"attentionEvidence", id:input.context_id, referenceID:input.reference_id} ]});
      const source = response.values[0];
      if (!source) return {status:"pending",code:"attention_not_delivered"};
      if (source.image) {
        const bytes = Buffer.from(source.image.png, "base64");
        if (createHash("sha256").update(bytes).digest("hex") !== source.image.sha256) {
          throw new BridgeError({code:"invalid_snapshot",message:"Frozen image hash does not match its source."});
        }
        png = source.image.png;
      }
      return {status: png ? "source_pixels" : "source_pixels_unavailable", reference:source.reference, payload:source.payload,
        sha256:source.image?.sha256, pixelWidth:source.image?.pixelWidth, pixelHeight:source.image?.pixelHeight};
    });
    return png ? {...result, content:[...result.content, {type:"image" as const, mimeType:"image/png", data:png}]} : result;
  });
  server.registerTool("notebook_read_context", {
    outputSchema: notebookResponseSchema,
    title: "Read a bounded page of shared history",
    description: "With context_id read immutable entries; without it read context summaries. Each page has an exact readCursor and nextEntryID or nextContextID. Continue using after_id and the same read_cursor. A changed snapshot refuses continuation; restart from the first page. Summary previews are not the full history. Maximum 64 entries and 4 MiB per page.",
    inputSchema: z.object({context_id:z.uuid().optional(),after_id:z.uuid().optional(),
      read_cursor:z.string().regex(/^(0|[1-9][0-9]*)$/).optional(),limit:z.number().int().min(1).max(64).default(32)})
      .strict().refine(value => !value.after_id || value.read_cursor !== undefined, "Continuation requires read_cursor"),
    annotations: {readOnlyHint:true,openWorldHint:false},
  }, input => actionResult(() => store.read({kind:input.context_id ? "contextEntries" : "contexts",
    id:input.context_id,after:input.after_id,revision:input.read_cursor,limit:input.limit})));
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
      label: value.label, revision: value.source_revision ?? (await runBridge<{revision:string}>(store.socketPath,
        {command:"reference",target:value.target,elementID:value.element_id})).revision })));
    return { status: "saved", context: await runBridge(store.socketPath, {command:"point",references,
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
      const request = await runBridge<{ id: string; sourceRevision: string }>(store.socketPath, { command: "render", target: input.target,
        expectedRevision: input.expected_revision, region: input.region, worldOrigin: input.world_origin, pageIndex: input.page_index });
      const deadline = Date.now() + input.wait_ms;
      do {
        const receipt = await store.readTargetRenderReceipt(request.id);
        if (receipt?.request.sourceRevision === request.sourceRevision) {
          if (receipt.status === "ready") {
            const current = await runBridge<{revision:string}>(store.socketPath, {command:"reference",target:input.target});
            if (current.revision !== request.sourceRevision) throw new BridgeError({code:"revision_conflict",message:"Содержимое изменилось во время подготовки снимка."});
            png = await store.readArtifact({ kind: "target", id: request.id, expectedSHA256: receipt.pngSHA256 });
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
    description: "Calculate one complete composition without writing content. Items have unique IDs, sizes and an existing source or preceding item as anchor. Fixed objects and final ink remain obstacles. Only explicitly movable subjects in context_id or additional_owners may be rearranged, and only if the package cannot fit otherwise. Return placements, necessary moves and exact expected versions for notebook_apply. A full surface returns placement_unavailable for the whole package. placement_budget means bounded preparation could not complete: reduce the package or region; no partial placement was produced. snapshot_pending never means empty paper.",
    inputSchema: z.object({ target: targetSchema, expected_revision: z.string(), context_id: z.uuid().optional(),
      additional_owners: z.array(targetSchema).max(32).default([]), world_origin: world.optional(),
      items: z.array(z.object({ id: z.string().min(1).max(120), size: z.object({width:z.number().positive().max(2048),height:z.number().positive().max(2048)}).strict(),
        relative_to: referenceSchema.optional(), relative_to_id: z.string().min(1).max(120).optional(), direction: z.enum(["right","below","free"]).default("free") }).strict()).min(1).max(32),
      movable: z.array(z.object({target:targetSchema,element_id:z.string().min(1).max(120).optional()}).strict()).max(32).default([]) }).strict(),
    annotations: {readOnlyHint:true,openWorldHint:false},
  }, input => actionResult(() => runBridge(store.socketPath,{command:"placement",placement:{ target:input.target,expectedRevision:input.expected_revision,
    contextID:input.context_id,additionalOwners:input.additional_owners,worldOrigin:input.world_origin,
    items:input.items.map(item=>({id:item.id,size:item.size,relativeTo:item.relative_to,relativeToID:item.relative_to_id,direction:item.direction})),
    movable:input.movable.map(subject=>({target:subject.target,elementID:subject.element_id})) }})));

  server.registerTool("notebook_search", {
    outputSchema: notebookResponseSchema,
    title: "Find a thought across the whole board tree",
    description: "Search titles, document blocks and agent text on pages, boards and covers. Each result includes its physical path and a stable reference. Handwriting is available through notebook_page_map and images.",
    inputSchema: z.object({ query: z.string().trim().min(1).max(500), limit: z.number().int().min(1).max(100).default(20) }).strict(),
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ query, limit }) => actionResult(() => runBridge(store.socketPath, {command:"search",query,limit})));
}
