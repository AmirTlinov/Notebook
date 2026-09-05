import { notebookResponseSchema } from "./contracts.js";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { targetSchema, referenceSchema, actionResult, type Target } from "./actions.js";
import { runBridge, BridgeError } from "./bridge.js";
import { NotebookStore } from "./store.js";
import { revision } from "./domain.js";

const frame = z.object({ x: z.number().finite(), y: z.number().finite(), width: z.number().positive(), height: z.number().positive() }).strict();
const world = z.object({ tileX: z.number().int(), tileY: z.number().int(), localX: z.number().finite(), localY: z.number().finite() }).strict();
export function registerCollaborationTools(server: McpServer, store: NotebookStore) {
  server.registerTool("notebook_point", {
    outputSchema: notebookResponseSchema,
    title: "Point to the source and share your interpretation",
    description: "Attach a short interpretation or question to an exact owner, element/block or local region. The reference follows its physical owner. This changes shared attention and keeps the human camera. Omit target to clear the agent pointer.",
    inputSchema: z.object({ target: targetSchema.optional(), element_id: z.string().optional(), region: frame.optional(), world_origin: world.optional(), page_index: z.number().int().nonnegative().default(0), label: z.string().max(1000).default("") }).strict(),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, input => actionResult(async () => {
    const reference = input.target ? { id: randomUUID(), target: input.target, elementID: input.element_id,
      region: input.region, worldOrigin: input.world_origin, pageIndex: input.page_index, label: input.label,
      ...(await runBridge<{ revision: string }>(store.root, { command: "reference", target: input.target, elementID: input.element_id })) } : undefined;
    return { status: "saved", attention: await runBridge(store.root, { command: "point", reference }) };
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
    description: "Calculate a frame against current items, elements and final visible Pencil pixels. The first request may prepare an ink map; repeat when ready. Pass the returned frame, worldOrigin and expected versions to notebook_apply. A full sheet returns placement_unavailable with a continuation suggestion.",
    inputSchema: z.object({target:targetSchema,expected_revision:z.string(),size:z.object({width:z.number().positive().max(2048),height:z.number().positive().max(2048)}),relative_to:referenceSchema.optional(),direction:z.enum(["right","below","free"]).default("free")}).strict(),
    annotations:{readOnlyHint:true,openWorldHint:false},
  }, input => actionResult(() => runBridge(store.root,{command:"placement",target:input.target,expectedRevision:input.expected_revision,
    size:input.size,reference:input.relative_to,direction:input.direction})));
  server.registerTool("notebook_search", {
    outputSchema: notebookResponseSchema,
    title: "Find a thought across the whole board tree",
    description: "Search titles, document blocks and agent text on pages, boards and covers. Each result includes its physical path and a stable reference. Handwriting is available through notebook_page_map and images.",
    inputSchema: z.object({ query: z.string().trim().min(1).max(500), limit: z.number().int().min(1).max(100).default(20) }).strict(),
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, ({ query, limit }) => actionResult(() => store.withReadSnapshot(async () => {
    const workspace = await store.readWorkspace();
    const hierarchy = await store.readBoardHierarchy(workspace);
    const hits: Array<{ target: Target; elementID?: string | undefined; title: string; path: string[]; preview: string; revision: string }> = [];
    const items = new Map(workspace.items.map(item => [item.id.toLowerCase(), item]));
    const parents = new Map<string,string>();
    for (const node of hierarchy.boards) for (const id of [...node.board.freeItems.map(p => p.itemID), ...node.board.stacks.flatMap(s => s.itemIDs)]) parents.set(id.toLowerCase(),node.id);
    const pathFor = (id: string): string[] => {
      const result: string[] = []; const seen = new Set<string>();
      while (!seen.has(id.toLowerCase())) {
        seen.add(id.toLowerCase()); const item = items.get(id.toLowerCase());
        result.unshift(item?.title || (id.toLowerCase() === workspace.rootBoardID.toLowerCase() ? "Корневая доска" : `#${id.slice(0,8)}`));
        const parent = parents.get(id.toLowerCase()); if (!parent) break; id = parent;
      }
      return result;
    };
    const add = (target:Target,title:string,text:string,ownerRevision:string,elementID?:string,path = pathFor(target.id)) => {
      const index = text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase()); if (index < 0) return;
      hits.push({ target, elementID, title, path, preview: text.slice(Math.max(0,index-60), index+180), revision:ownerRevision });
    };
    for (const node of hierarchy.boards) {
      for (const element of node.board.elements) {
        const target:Target = element.surface.kind === "cover" ? {kind:"cover",id:element.surface.ownerID!,boardID:node.id} : {kind:"board",id:node.id};
        add(target,element.id,element.source || element.html,revision(node.board.stamp),element.id);
      }
    }
    for (const item of workspace.items) {
      const boardID = parents.get(item.id.toLowerCase()) ?? workspace.rootBoardID;
      const board = hierarchy.boards.find(n => n.id.toLowerCase() === boardID.toLowerCase())!.board;
      add(item.kind === "board" ? {kind:"board",id:item.id} : {kind:"cover",id:item.id,boardID},item.title,item.title,revision(board.stamp));
      if (item.kind === "notebook") for (const [index,id] of item.pageIDs.entries()) {
        const page = await store.readPage(id);
        for (const element of page.elements) add({kind:"page",id},item.title,element.source || element.html,revision(page.agentStamp),element.id,[...pathFor(item.id),`Лист ${index+1}`]);
      }
      if (item.kind === "document") {
        const document = await store.readDocument(item.id);
        for (const block of document.blocks) add({kind:"document",id:item.id},item.title,block.kind === "interactive" ? block.html : block.source,revision(document.contentStamp),block.id);
      }
    }
    const results = await Promise.all(hits.slice(0,limit).map(async hit => ({...hit,reference:{id:randomUUID(),target:hit.target,elementID:hit.elementID,label:hit.preview,
      ...(await runBridge(store.root,{command:"reference",target:hit.target,elementID:hit.elementID}))}})));
    return {status:"ready",results,total:hits.length,truncated:hits.length>limit};
  })));
}
