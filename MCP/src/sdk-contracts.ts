import * as z from "zod/v4";
import { actionSchema, operationSchema, targetSchema, referenceSchema } from "./actions.js";
import { presentationStepSchema } from "./presentation.js";
import { sceneBoundsSchema, worldPointSchema } from "./spatial.js";

const id=z.uuid(), text=z.string();
const observationScope=z.object({target:targetSchema,ids:z.array(text.min(1).max(120)).min(1).max(32).optional(),fields:z.array(z.enum(["preview","content","state","geometry"])).min(1).max(4).optional(),expand:z.array(z.enum(["incoming","outgoing","neighbors","container"])).max(4).optional(),bounds:sceneBoundsSchema.optional()}).strict();
const query=z.object({kind:z.enum(["observation","workspaceHeader","itemHeaders","itemHeader","workingSet","sceneWindow","scenePaintOrder","page","pageHeader","pageElement","documentHeader","document","documentState","documentBlock","boardItem","boardElement","boardContentRevision","ownerBoard","notebookPages","notebookDirectory","notebookPosition","spatialInk","presence","attentionEvidence","contexts","contextEntries","actions","currentViewReceipt","pageVisionReceipt","targetRenderReceipt","renderRequests","delivery","actionSnapshots","runtime","codeFragment","codeFragments"]),
  scope:observationScope.optional(),since:text.max(196608).optional(),next:text.max(196608).optional(),
  id:id.optional(),after:id.optional(),referenceID:id.optional(),revision:text.optional(),limit:z.number().int().positive().optional(),
  itemIDs:z.array(id).max(8).optional(),pageIDs:z.array(id).max(4).optional(),boardIDs:z.array(id).max(8).optional(),
  surfaces:z.array(z.object({kind:z.enum(["board","cover","codeFragment"]),ownerID:id.optional()}).strict()).max(8).optional(),
  pinnedIDs:z.array(id).optional(),bounds:sceneBoundsSchema.optional(),coverID:id.optional(),paintCursor:text.optional(),
  pageIndex:z.number().int().nonnegative().optional(),pages:z.array(z.json()).max(4).optional(),itemID:id.optional(),
  visibleRoot:text.optional(),contextID:id.optional(),elementID:text.optional(),file:z.object({computer:id,project:text,root:text,path:text}).strict().optional()}).strict();
const action=z.object({summary:actionSchema.shape.summary,contextID:id.optional(),additionalOwners:z.array(targetSchema).max(32).optional(),
  references:z.array(referenceSchema).max(32).optional(),expected:actionSchema.shape.expected,operations:z.array(operationSchema).min(1).max(512)}).strict();
const frame=z.object({x:z.number(),y:z.number(),width:z.number().positive(),height:z.number().positive()}).strict();
const image=z.object({kind:z.enum(["currentView","target","pageOverview","pageRegion","attention","scriptImage"]),id:id.optional(),contextID:id.optional(),referenceID:id.optional(),
  regionID:text.optional(),mode:z.enum(["faithful","ink"]).optional(),expectedSHA256:text.regex(/^[a-f0-9]{64}$/)}).strict();
const catalogue: Record<string,{input:z.ZodType;returns:string;example:string;old?:string[]}> = {
  help:{input:z.object({topic:text.optional()}).strict(),returns:"Index, or exact method input schema, result description and example. operations is a compact index of 20 variants; operation/<name> gives one exact schema. interactive explains embedded notebook.ready(promise); execution explains terminal status and output pagination.",example:"await emit(await nb.help('operation/createDocument'));"},
  observe:{input:z.object({contextID:id.optional(),target:targetSchema.optional(),elementID:text.optional(),blockID:text.optional(),ids:observationScope.shape.ids,fields:observationScope.shape.fields,expand:observationScope.shape.expand,bounds:sceneBoundsSchema.optional(),limit:z.number().int().min(1).max(32).optional(),includeImage:z.boolean().optional(),since:z.record(text,z.json()).optional(),next:text.max(196608).optional()}).strict(),returns:"{header,presence,presenceGeneration,content,contexts,connection,cursor,changeKeys,changes,visual}. content has objects:{target,id,change:upsert|deleted|outOfScope,value?}[], mode:snapshot|delta, coverage:{complete,next?}, checkpoint only when complete. Drain coverage.next using next (not since); then pass last changeKeys as since. Continuation pins workspace/scope/fields/expand/source commit, rejects stale/expired explicitly; changing scope with since starts a bounded snapshot. read/readMany also accept {kind:'observation',scope,since:checkpoint,next,limit}. fields selects preview/content/state/geometry; one-hop expand from 1-32 ids supports incoming/outgoing/neighbors/container through native indices and grants no mutation rights. bounds restricts a board/cover spatial window to at most 256 addresses, otherwise returns observation_scope_full (narrow bounds or page the owner without bounds). Dependent geometry is invalidated when endpoints/ink claims change. Unchanged bodies are not decoded. Presence generation is separate from content change cursor; images require includeImage:true.",example:"let r=await nb.observe({target:args.target}); while(r.content.coverage?.next) r=await nb.observe({target:args.target,next:r.content.coverage.next}); await emit(r);",old:["notebook_observe"]},
  read:{input:query,returns:"{cursor:string,values:[owner]}; native typed owner. An absent optional owner is null, bounded scene/directory reads carry coverage/cursors.",example:"await emit(await nb.read({kind:'itemHeaders',limit:20}));"},
  readMany:{input:z.object({queries:z.array(query).max(128),expectedCursor:text.optional()}).strict(),returns:"{cursor:string,values:owner[]}, one atomic snapshot. At most 4 pages/8 heavy owners, 4 attention sources, one context directory/page.",example:"await emit(await nb.readMany({queries:[{kind:'workspaceHeader'},{kind:'presence'}]}));"},
  board:{input:z.object({id:id.optional(),bounds:sceneBoundsSchema.optional(),limit:z.number().int().min(1).max(128).optional(),pinnedIDs:z.array(id).optional()}).strict(),returns:"{cursor,values:[sceneWindow]}; sceneWindow has header,boards[].board,boardContentRevisions,items,totalMatches,truncated. Defaults to human viewport.",example:"const scene=await nb.board({}); await emit(scene);",old:["notebook_read_board"]},
  notebook:{input:z.object({id,pageIndex:z.number().int().nonnegative().optional(),limit:z.number().int().min(1).max(4).optional(),visibleRoot:text.optional()}).strict(),returns:"{cursor,values:[directory]}; directory.header has item/pageCount/visibleRoot, pages contain position and revisions, nextIndex is continuation. Cover data: read({kind:'scenePaintOrder',id:boardID,coverID:notebookID,bounds,...}).",example:"await emit(await nb.notebook({id:args.notebookID,limit:4}));",old:["notebook_read_notebook"]},
  page:{input:z.object({id:id.optional(),elementID:text.optional()}).strict(),returns:"Full {page:{id,size,elements,...},agentRevision,drawingRevision,cursor}, or {cursor,values:[{header,element,graphicResolution?}|null]} with elementID. Header includes content/ink stamps from the same snapshot. For metadata only use read kind pageHeader; no implicit camera movement.",example:"const p=await nb.page({id:args.pageID}); await emit(p);",old:["notebook_read_page"]},
  document:{input:z.object({id:id.optional(),blockID:text.optional()}).strict(),returns:"Full {document,state,contentRevision,stateRevision,cursor}, or native read envelope of one documentBlock when blockID is supplied. Prefer blockID for one block, or project selected fields before emit to avoid repeating an entire document.",example:"const d=await nb.document({id:args.documentID}); await emit({id:d.document.id,contentRevision:d.contentRevision,stateRevision:d.stateRevision});",old:["notebook_read_document"]},
  context:{input:z.object({id:id.optional(),after:id.optional(),revision:text.optional(),limit:z.number().int().min(1).max(64).optional()}).strict(),returns:"{cursor,values:[directory|entryPage]}; pass returned nextContextID/nextEntryID as after and readCursor as revision.",example:"await emit(await nb.context({id:args.contextID,limit:8}));",old:["notebook_read_context"]},
  attention:{input:z.object({contextID:id,referenceID:id}).strict(),returns:"{status:source_pixels|source_pixels_unavailable|pending,reference,payload,artifact?,pixelWidth?,pixelHeight?}; immutable source of the sent human question.",example:"const s=await nb.attention(args); await emit(s); if(s.artifact) await emitImage(s.artifact);",old:["notebook_read_attention"]},
  code:{input:z.union([z.object({id}).strict(),z.object({file:query.shape.file.unwrap(),after:id.optional(),limit:z.number().int().max(64).optional()}).strict()]),returns:"Preserved fragment, ink, revision, inkRevision, notebook://code link; file form returns bounded fragments.",example:"await emit(await nb.code({id:args.fragmentID}));",old:["notebook_read_code_notes"]},
  search:{input:z.object({query:text.min(1).max(500),limit:z.number().int().min(1).max(100).optional(),filters:z.object({kinds:z.array(z.enum(["item","page","document","spatial"])).min(1).max(4).optional(),target:targetSchema.optional()}).strict().optional(),next:text.max(16384).optional()}).strict(),returns:"{status,results,total,truncated,coverage:{complete,next?}}. next continues the same normalized query and filters in stable source-kind/address order; page size may change. filters.kinds selects titles, page elements, document blocks or spatial elements; filters.target restricts the exact page/document/board/cover surface, not recursive descendants. Source commits cause search_cursor_stale; restart explicitly without next. Presence/run events do not invalidate the cursor. total counts matching index entries, not decoded owner bodies; no handwriting OCR is inferred.",example:"await emit(await nb.search({query:'Transformer',limit:10}));",old:["notebook_search"]},
  reference:{input:z.object({target:targetSchema,elementID:text.optional()}).strict(),returns:"{revision}, source identity including composition geometry where applicable.",example:"await emit(await nb.reference({target:{kind:'page',id:args.pageID}}));"},
  referenceStatus:{input:z.object({reference:referenceSchema}).strict(),returns:"{status:current|changed|checking|review_required|target_missing,currentRevision?,fingerprint?}; strictly read-only. checking means prepare via render if pixels are needed.",example:"await emit(await nb.referenceStatus({reference:args.reference}));"},
  action:{input:z.object({actionID:id.optional(),contextID:id.optional(),limit:z.number().int().min(1).max(50).optional(),after:id.optional(),
    section:z.enum(["operations","revisions","changes","continuations","undo","snapshots"]).optional(),offset:z.number().int().nonnegative().optional(),pageSize:z.number().int().min(1).max(64).optional()}).strict(),returns:"Default: Array of {receipt,continuations,delivery,snapshots,pages,publication}; receipt is a compact projection without source values or field inverses. Arrays contain 32 entries by default; pages[section] gives total/nextOffset. actionID+section+offset returns [{actionID,page:{section,offset,total,nextOffset,items}}]. Section operations gives kind/target/id/frame; changes and undo give file/path, never before/after. Without actionID, nextActionID continues with after. receipt.actionVersion identifies the exact saved effect, including undo, independently of the raw request fingerprint. publication distinguishes saved/received/shown using exact actionVersion and revisions; delivery.sameActionVersion is false for historical versionless receipts and stale phases. Reading never invents or upgrades an acknowledgement. shownOnIPad is confirmed only by actual native display evidence, awaiting_display when required pixels are unconfirmed, or not_required when no new content was produced. Its shownOnIPadReason is undo_without_visual_changes for completed undo with restored zero/no changed revisions, or action_without_visual_changes for an original saved action with no field changes/no changed revisions. not_required is not a display acknowledgement; receivedByIPad remains independent. snapshots cover matching receipts in the latest 80 render requests.",example:"const a=await nb.action({actionID:args.actionID}); await emit(a); const next=a[0].pages.operations.nextOffset; if(next!==null) await emit(await nb.action({actionID:args.actionID,section:'operations',offset:next}));",old:["notebook_action"]},
  render:{input:z.object({target:targetSchema,expectedRevision:text,region:frame.optional(),worldOrigin:worldPointSchema.optional(),pageIndex:z.number().int().nonnegative().optional()}).strict(),returns:"{status:pending,request} or target render receipt with exact source and artifact. Retain the same owner/revision and retry after nb.wait. No camera movement.",example:"const r=await nb.render(args); await emit(r); if(r.artifact) await emitImage(r.artifact);",old:["notebook_render"]},
  pageMap:{input:z.object({id:id.optional(),drawingRevision:text.optional(),sinceDrawingRevision:text.optional()}).strict(),returns:"{status,drawingRevision,map}; map.regions names exact final-pencil crops. A cold source returns pending request.",example:"await emit(await nb.pageMap({id:args.pageID}));",old:["notebook_page_map"]},
  pageImage:{input:z.object({id:id.optional(),drawingRevision:text.optional(),mode:z.enum(["faithful","ink"]).optional()}).strict(),returns:"{status,drawingRevision,artifacts[]}; faithful pencil overview with grid, or ink-only.",example:"const r=await nb.pageImage({id:args.pageID}); for(const a of r.artifacts??[]) await emitImage(a);",old:["notebook_render_page"]},
  regions:{input:z.object({id:id.optional(),drawingRevision:text,regionIDs:z.array(text).min(1).max(4),mode:z.enum(["faithful","ink"]).optional()}).strict(),returns:"{status,drawingRevision,artifacts[]} ordered exactly as requested regionIDs; an erased/stale region is refused.",example:"const r=await nb.regions(args); for(const a of r.artifacts??[]) await emitImage(a);",old:["notebook_render_region","notebook_render_regions"]},
  place:{input:z.object({target:targetSchema,expectedRevision:text,contextID:id.optional(),additionalOwners:z.array(targetSchema).max(32).optional(),worldOrigin:worldPointSchema.optional(),
    items:z.array(z.object({id:text,size:z.object({width:z.number().positive().max(2048),height:z.number().positive().max(2048)}).strict(),relativeTo:referenceSchema.optional(),relativeToID:text.optional(),direction:z.enum(["right","below","free"])}).strict()).min(1).max(32),
    movable:z.array(z.object({target:targetSchema,elementID:text.optional()}).strict()).max(32).optional()}).strict(),returns:"One complete placement package, exact expected revisions and necessary moves; pending/full/budget failure produces no partial placement. Omitted movable/additionalOwners mean empty arrays; existing content cannot move unless explicitly authorized.",example:"const p=await nb.page({id:args.pageID}); await emit(await nb.place({target:{kind:'page',id:p.page.id},expectedRevision:p.agentRevision,items:[{id:'next-note',size:{width:180,height:100},direction:'free'}]}));",old:["notebook_place"]},
  transaction:{input:z.object({key:text.min(1).max(120),action}).strict(),returns:"Array of {receipt,pages,publication:{saved:'confirmed'},readDetails}; receipt is compact: id, action summary/context/references/results without values, revisions, addressed changes, optional undo. Pages cover 32 results by default; call action({actionID,section,offset}) for more. This saved proof is independent of delivery/current UI reads. One atomic action, stable ID from run_id/key; raw fingerprint is checked before Markdown normalization. Native source/state/ink expectations remain enforced.",example:"const p=await nb.page({id:args.pageID}); const r=await nb.transaction('explain',{summary:'Пояснение',expected:[{target:{kind:'page',id:p.page.id},revision:p.agentRevision}],operations:[{kind:'insertElement',target:{kind:'page',id:p.page.id},id:'explanation',values:{kind:'markdown',source:'# Пример',frame:{x:20,y:30,width:300,height:180}}}]}); await emit(r);",old:["notebook_apply"]},
  undo:{input:z.object({key:text.min(1).max(120),actionID:id}).strict(),returns:"Compact actionDetails; undo preserves later human fields. receipt.undo reports restored/preservedCount, while pages.undo and action({actionID,section:'undo',offset}) expose every preserved address.",example:"await emit(await nb.undo('undo-explanation',{actionID:args.actionID}));",old:["notebook_undo"]},
  point:{input:z.object({key:text.min(1).max(120),contextID:id.optional(),replyTo:id.optional(),references:z.array(referenceSchema.partial({id:true,revision:true})).min(1).max(32)}).strict(),returns:"Durable shared-context entry. Reply requires contextID and replyTo. Does not alter human camera/selection.",example:"await emit(await nb.point('source',{references:[{target:{kind:'page',id:args.pageID},label:'Рассмотренный лист'}]}));",old:["notebook_point"]},
  presentation:{input:z.object({id:id.optional()}).strict(),returns:"Current iPad view capability/presence, or exact presentation receipt by ID.",example:"await emit(await nb.presentation({}));"},
  present:{input:z.object({key:text.min(1).max(120),view:z.object({deviceID:id,sessionID:id,sequence:z.number().int().nonnegative(),nonce:id}).strict(),steps:z.array(presentationStepSchema).min(1).max(12)}).strict(),returns:"Sent/playing/completed/interrupted receipt. Human contact interrupts; read presentation({id}) for actual shown state. No replay after reconnect.",example:"const view=await nb.presentation({}); await emit(await nb.present('show',{view:view.view,steps:args.steps}));",old:["notebook_present"]},
  cancelPresentation:{input:z.object({key:text.min(1).max(120),id}).strict(),returns:"Native interruption receipt for the explicitly named presentation; does not change saved content.",example:"await emit(await nb.cancelPresentation('stop-show',{id:args.presentationID}));",old:["notebook_present"]},
  export:{input:z.object({key:text.min(1).max(120),documentID:id}).strict(),returns:"{status:queued,jobID,documentID,contentRevision}; job continues outside JS time in the markup App Sandbox, with at most two compiler slots and 120 seconds each. Pinned Tectonic 0.16.9 and the full offline TeX 2022 distribution support custom preambles/packages, including TikZ and siunitx. Embedded SVG (including inline SVG), PNG and JPEG are included; valid internal anchors and HTTP/HTTPS/mailto links remain active in the PDF. Missing internal links are visibly marked. No user-cache, external user-file or network image access. TeX <=4 MiB; at most 128 images, <=16 MiB combined source images and <=8 MiB prepared images; PDF <=16 MiB, PDF plus prepared images <=17 MiB. The native owner verifies the document revision before atomically publishing the complete package.",example:"await emit(await nb.export('pdf',{documentID:args.documentID}));",old:["notebook_export_document"]},
  exportStatus:{input:z.object({jobID:id}).strict(),returns:"Queued/running/saved/failed/interrupted job; saved receipt contains immutable texPath/pdfPath, PDF sha256, assets with their exact paths and hashes, and packageSHA256 covering TeX, PDF and every image. Keep the whole package to recompile TeX. Historical receipts without package metadata remain readable.",example:"await emit(await nb.exportStatus({jobID:args.jobID}));"},
  wait:{input:z.object({milliseconds:z.number().int().min(0).max(1000)}).strict(),returns:"null after bounded async wait; does not hold interpreter CPU or native writer.",example:"await nb.wait({milliseconds:100});"},
  id:{input:z.object({key:text.min(1).max(120)}).strict(),returns:"Stable UUID derived from run_id and key, without a write.",example:"const id=await nb.id('diagram'); await emit(id);"},
  emit:{input:z.object({value:z.json()}).strict(),returns:"Durable output event with sequence. Output is paginated; no silent truncation.",example:"await emit({answer:42});"},
  emitImage:{input:z.object({artifact:image}).strict(),returns:"Durable reference to exact native pixels, returned as MCP image content.",example:"await emitImage((await nb.render(args)).artifact);"},
};

const operationDescriptions:Record<z.infer<typeof operationSchema>["kind"],string>={
  appendInkStroke:"Append native pen samples to a page, board, cover or code fragment.",
  convertInkToElement:"Convert 1–16 existing pen strokes on the same physical owner into native geometry. Requires inkRevision. sourceInkIDs remain immutable; undo restores original ink. The graphic must be visible and use geometry representation.",
  insertElement:"Insert a native graphic, Markdown, a web program, or nativeText (board/cover) with a frame. Board elements require values.worldOrigin (tiled world anchor); their frame is relative to that anchor. Omit worldOrigin on cover/page elements, whose frame belongs to the surface.",
  updateElement:"Change a named element's source, style or frame.",
  setElementState:"Replace the JSON state of a named web element.",
  removeElement:"Remove one named element. Native graphics retain their identity and hide reversibly; source ink is not deactivated.",
  reorderElements:"Set the order of named elements in an owner.",
  insertBlock:"Insert a Markdown, LaTeX or interactive document block; afterID places it after another block.",
  updateBlock:"Change a document block's source or height.",
  setBlockState:"Replace the JSON state of a named interactive document block.",
  removeBlock:"Remove one named document block.",
  reorderBlocks:"Set the order of named document blocks.",
  setPreamble:"Replace the document's TeX preamble.",
  replaceDocument:"Replace the document's preamble and blocks in one operation.",
  createNotebook:"Create a notebook at a board position.",
  createDocument:"Create a document with paper size and blocks at a board position.",
  createBoard:"Create a board at a board position.",
  renameItem:"Change one item's title. target is its containing board, never workspace; expected must include that board and the root workspace catalogue.",
  moveItem:"Move one item to a tiled board position.",
  stackItems:"Stack two to five named items.",
};
const compositionRule="Geometry of existing content requires a source reference covering each moved subject, or its exact owner in action.additionalOwners. With contextID, only that context's stored references establish source scope; adding action.references cannot widen it. Without contextID, action.references establish it. Current selection/camera and expected revisions alone do not grant composition scope. New subjects created in the same action need no extra scope. A composition_scope rejection saves none of the atomic action.";
const moveExample=`const target = {kind:'board',id:args.boardID};
const owner = {kind:'cover',id:args.itemID,boardID:args.boardID};
const scene = (await nb.board({id:args.boardID})).values[0];
await emit(await nb.transaction('move-item', {
  summary:'Переместить выбранный предмет', additionalOwners:[owner],
  expected:[{target,revision:scene.boardContentRevisions[args.boardID.toLowerCase()]}],
  operations:[{kind:'moveItem',target,id:args.itemID,
    values:{center:{tileX:0,tileY:0,localX:100,localY:80}}}]
}));`;
const renameExample=`const boardID = (await nb.read({kind:'ownerBoard',id:args.itemID})).values[0];
if (!boardID) throw new Error('Item has no containing board');
const scene = (await nb.board({id:boardID})).values[0];
const target = {kind:'board',id:boardID};
const workspace = {kind:'workspace',id:scene.header.rootBoardID};
const stamp = scene.header.stamp;
await emit(await nb.transaction('rename-item', {
  summary:'Переименовать предмет',
  expected:[{target,revision:scene.boardContentRevisions[boardID.toLowerCase()]},
    {target:workspace,revision:stamp.counter+'@'+stamp.actor.toLowerCase()}],
  operations:[{kind:'renameItem',target,id:args.itemID,values:{title:args.title}}]
}));`;
const blockStateExample=`const d = await nb.document({id:args.documentID});
const target = {kind:'document',id:d.document.id};
await emit(await nb.transaction('set-program-state', {
  summary:'Обновить состояние программы',
  expected:[{target,revision:d.contentRevision,stateRevision:d.stateRevision}],
  operations:[{kind:'setBlockState',target,id:args.blockID,values:{state:args.state}}]
}));`;
const geometryScope:Partial<Record<z.infer<typeof operationSchema>["kind"],string>>={
  moveItem:"The operation target is the containing board. The moved subject is {kind:'cover',id:itemID,boardID:boardID}; declare that cover in action.additionalOwners when no source context covers it. Listing only the board is insufficient. A context reference to this notebook's page also covers its physical carrier.",
  stackItems:"Declare each existing item's {kind:'cover',id:itemID,boardID:target.id} in action.additionalOwners unless source references already cover all carriers.",
  updateElement:"Changing frame or worldOrigin of an existing element requires scope for that element. Declare operation.target in action.additionalOwners, or reference its elementID/a source region that intersects its current geometry. Source/style-only edits do not add a geometry requirement.",
  reorderElements:"Every existing named element needs source scope, or declare operation.target in action.additionalOwners. Elements created earlier in this same action are exempt.",
};
const creationOwner="Creation changes two existing owners: the containing board and the root workspace catalogue. Read both from one nb.board({id:boardID}) result: expected needs {target:{kind:'board',id:scene.boardID},revision:scene.boardContentRevisions[scene.boardID.toLowerCase()]} and {target:{kind:'workspace',id:scene.header.rootBoardID},revision:scene.header.stamp.counter+'@'+scene.header.stamp.actor.toLowerCase()}. New item IDs have no prior revision; do not invent an expected entry for them.";
const createDocumentExample="const s=(await nb.board({})).values[0]; const boardID=s.boardID; await emit(await nb.transaction('document',{summary:'Учебный документ',expected:[{target:{kind:'board',id:boardID},revision:s.boardContentRevisions[boardID.toLowerCase()]},{target:{kind:'workspace',id:s.header.rootBoardID},revision:s.header.stamp.counter+'@'+s.header.stamp.actor.toLowerCase()}],operations:[{kind:'createDocument',target:{kind:'board',id:boardID},values:{title:'Пример',center:{tileX:0,tileY:0,localX:0,localY:0},paperSize:'a4',blocks:[{id:'intro',kind:'markdown',source:'# Введение'}]}}]}));";
const operationDetails=Object.fromEntries(operationSchema.options.map(schema=>{
  const name=schema.shape.kind.value;
  return [name,{name,description:operationDescriptions[name],input:z.toJSONSchema(schema,{reused:"ref"}),
    ...(name==="renameItem"?{owner:"Find the containing board with nb.read({kind:'ownerBoard',id:itemID}). Use its UUID in operation.target, and the item UUID in operation.id. expected includes this board's content revision and {kind:'workspace',id:scene.header.rootBoardID} with scene.header.stamp counter@actor. A title-only edit needs no geometry scope.",example:renameExample}:{}),
    ...(["createDocument","createNotebook","createBoard"].includes(name)?{owner:creationOwner,
      ...(name==="createDocument"?{example:createDocumentExample}:{} )}:{}),
    ...(name==="setBlockState"?{owner:"Use the document target and the block ID. The same expected entry requires both revision (contentRevision) and stateRevision from nb.document; either stale value rejects the entire transaction. values.state replaces the block's full JSON state.",example:blockStateExample}:{}),
    ...(geometryScope[name]?{compositionScope:{rule:compositionRule,owner:geometryScope[name]},
      ...(name==="moveItem"?{example:moveExample}:{} )}:{}),
    relatedTopics:["transaction","examples",...(name==="insertBlock"||name==="createDocument"?["interactive"]:[])]}];
}));
const interactiveBlock={kind:"interactive",html:'<button id="increment">Прибавить один</button> <output id="count"></output>',
  css:"button,output{font:24px -apple-system,sans-serif}button{padding:12px}",initialState:{count:0},height:120,
  javaScript:`const button = document.getElementById('increment');
const output = document.getElementById('count');
const draw = () => { output.textContent = String(notebook.state?.count ?? 0); };
button.addEventListener('click', () => {
  notebook.commit({count: (notebook.state?.count ?? 0) + 1});
  draw();
});
addEventListener('notebookstate', draw);
notebook.ready(Promise.resolve().then(draw));`};
const interactiveExample=`const d = await nb.document({id:args.documentID});
await emit(await nb.transaction('counter', {
  summary:'Интерактивный счётчик',
  expected:[{target:{kind:'document',id:d.document.id},revision:d.contentRevision}],
  operations:[{kind:'insertBlock',target:{kind:'document',id:d.document.id},id:'counter',values:${JSON.stringify(interactiveBlock,null,2)}}]
}));`;
const terminalStatuses=["completed","failed","cancelled","interrupted"];
const polling="Resume with after_seq=next_seq while status is queued/running OR has_more=true. Stop only when status is completed/failed/cancelled/interrupted AND has_more=false. running + has_more=false is normal: the current output is drained, but the program can still emit or save effects.";
export const sdkReference = {
  apiVersion:1,
  methods:Object.fromEntries(Object.entries(catalogue).map(([name,value])=>[name,{...value,input:z.toJSONSchema(value.input,{reused:"ref"})}])),
  operations:{description:"Choose operation/<name> for one exact schema. transaction contains the complete atomic action schema with shared $defs.",
    items:Object.values(operationDetails).map(({name,description})=>({name,topic:`operation/${name}`,description}))},
  operationDetails,
  execution:{polling,terminalStatuses,
    effects:"Each key has one durable identity. saved is backed by a native receipt or accepted export job. notSaved is a proven rejection/absence and is terminal: repeating the same key returns its stored error without dispatch. Correct the request using a new key and fresh revisions. outcomeUnknown means a durable witness could not be read, or the effect was transient presentation; no automatic replay. Startup reconciles unfinished effects even after their JS run has ended.",
    operationErrors:"A native operation rejection keeps its code/message and includes operation:{index,kind,target,id?}. index is zero-based in action.operations; id is bounded to 120 characters. No operation values/source are echoed. It is available on the caught JS error and effects[].error. Action-wide failures (for example an obsolete expected revision) have no invented operation index. All operations remain atomic: a rejection saves none, including earlier operations.",
    cancellation:"Cancel closes admission and interrupts JavaScript. The writer orders cancel against terminal completion; an accepted cancel ends with status:'cancelled', error.code:'run_cancelled'. Already accepted native effects finish and remain inspectable in effects; new effects are refused. A run that completed before cancel stays completed. Resume until terminal status AND has_more=false.",
    deadline:"The Mac owns a 30-second user execution deadline, including XPC sandbox launch and await. Expiration gives failed/script_timeout and stops new SDK effects even if the worker never entered main. Already accepted effects drain into their receipts before terminal publication. Queued runs have not started this budget. Trusted normalization has its own 8-second deadline; a persisted PDF job has a separate 120-second compiler deadline. Neither queue needs the user worker to answer cancellation.",
    exampleScope:"MCP client orchestration, outside Notebook JavaScript. reply is the initial notebook_execute structuredContent; consume handles each output event. For response_pending retain its original run_id/after_seq and follow the reply_deadline recovery contract.",
    example:`const terminal = ${JSON.stringify(terminalStatuses)};
for (;;) {
  if (reply.status === 'error') throw new Error(reply.message);
  for (const event of reply.events) await consume(event);
  if (terminal.includes(reply.status) && reply.has_more === false) return reply;
  reply = await callNotebookExecute({op:'resume',run_id:reply.run_id,after_seq:reply.next_seq,wait_ms:1000});
}`},
  interactive:{description:"Embedded document programs have DOM plus notebook.state, notebook.commit(next) and notebook.ready(promise). These are separate from the universal executor's nb API.",
    readiness:"Call notebook.ready(promise) while installing the program; resolve it only after the initial drawing and any asynchronous setup are complete. ready marks initial presentation readiness, not the end of future interaction. A program with no declaration produces program_completion_unknown when rendered.",
    state:"notebook.commit(next) publishes complete JSON state; redraw locally after a click. Listen for the notebookstate event to redraw remote or restored state. This local commit is not itself a durable-save receipt.",
    requiredArgs:{documentID:"Read the document UUID from Notebook first."},block:interactiveBlock,example:interactiveExample,
    relatedTopics:["operation/insertBlock","operation/createDocument","transaction"]},
  examples:{
    createDocument:createDocumentExample,
    graphic:"insertElement: {kind:'graphic',source:'',frame:{x:20,y:20,width:100,height:100},graphic:{shape:'ellipse',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},label:'+',representation:'geometry',visible:true,sourceInkIDs:[]}}. For a board add worldOrigin. updateElement accepts a graphic patch, e.g. {graphic:{label:'?'}}; sourceInkIDs cannot be patched. convertInkToElement uses the same payload with existing sourceInkIDs and requires inkRevision.",
    connector:"A graphic with shape:'connector' has connection:{start:{point:{x:0,y:0},binding:{elementID:'a',normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:false}},end:{point:{x:100,y:0},binding:{elementID:'b',normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:false}},bend:0,startArrowhead:'none',endArrowhead:'arrow',labelPosition:0.5}. Points are element-local; bindings address native nodes on the same owner. Moving nodes derives the connection without changing its authored frame. Missing or hidden bound nodes hide the link, never detach it. Patch connection fields independently, e.g. {graphic:{connection:{bend:40},label:'1:2'}}. Replace an endpoint with {point:{x:...,y:...}} to detach explicitly. Styles support stroke, strokeWidth and dash solid/dashed/dotted. Heads: none/arrow/triangle/square/dot/pipe/diamond/inverted/bar. Read page/board/boardElement returns graphicResolution:{state:'geometry',frame} or {state:'hidden'} or {state:'pending',dependencies}; frame is derived, while the authored element.frame and binding values remain unchanged. Hidden means this geometry is not shown, including an ink representation; it does not remove intent. Undo reports retained_dependency addresses for later links that protect earlier node creation/conversion.",
    nativeText:"insertElement on board: {kind:'nativeText',source:'Подпись',worldOrigin:{tileX:0,tileY:0,localX:0,localY:0},frame:{x:0,y:0,width:200,height:80},textStyle:{fontSize:24,weight:0.45,red:0.09,green:0.09,blue:0.08,alpha:1}}. For a cover omit worldOrigin and use cover-local frame coordinates. Omit textStyle to use native defaults.",
    interactive:interactiveExample
  }
};
