import * as z from "zod/v4";
import { actionSchema, operationSchema, targetSchema, referenceSchema } from "./actions.js";
import { presentationStepSchema } from "./presentation.js";
import { sceneBoundsSchema, worldPointSchema } from "./spatial.js";
import {readBasisSchema,coverageSchema,snapshotSchema,actionResultSchema,readDataSchemas,methodDataSchemas,effectResultSchemas} from "./sdk-results.js";

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
  references:z.array(referenceSchema).max(32).optional(),base:z.union([readBasisSchema,z.array(readBasisSchema).min(1).max(32)]),operations:z.array(operationSchema).min(1).max(512)}).strict();
const frame=z.object({x:z.number(),y:z.number(),width:z.number().positive(),height:z.number().positive()}).strict();
const image=z.object({kind:z.enum(["currentView","target","pageOverview","pageRegion","attention","scriptImage"]),id:id.optional(),contextID:id.optional(),referenceID:id.optional(),
  regionID:text.optional(),mode:z.enum(["faithful","ink"]).optional(),expectedSHA256:text.regex(/^[a-f0-9]{64}$/)}).strict();
const catalogue: Record<string,{input:z.ZodType;returns:string;example:string;old?:string[]}> = {
  help:{input:z.object({topic:text.optional()}).strict(),returns:"Index, or exact method input schema, result description and example. operations is a compact index of 20 variants; operation/<name> gives one exact schema. interactive explains embedded notebook.ready(promise); execution explains terminal status and output pagination.",example:"await emit(await nb.help('operation/createDocument'));"},
  observe:{input:z.object({contextID:id.optional(),target:targetSchema.optional(),elementID:text.optional(),blockID:text.optional(),ids:observationScope.shape.ids,fields:observationScope.shape.fields,expand:observationScope.shape.expand,bounds:sceneBoundsSchema.optional(),limit:z.number().int().min(1).max(32).optional(),includeImage:z.boolean().optional(),since:text.max(196608).optional(),next:text.max(196608).optional()}).strict(),returns:"Snapshot of a bounded observation: data.objects, data.header, data.checkpoint, data.mode. coverage.next drains the same frozen scope; pass data.checkpoint as since only after complete. Fields/one-hop expansion/geometry remain Core-owned. Unknown selection is not guessed. Images only with includeImage:true.",example:"let r=await nb.observe({target:args.target}); while(r.coverage.next) r=await nb.observe({target:args.target,next:r.coverage.next}); await emit(r);",old:["notebook_observe"]},
  read:{input:query,returns:"Snapshot<T> selected by query.kind. data is one object or collection, never values[0]. basis contains exact owner versions from the SAME native snapshot, not mutation permissions. coverage.complete is explicit; next can be passed with the same kind to read. Stale continuation fails, without a hidden full rescan.",example:"const s=await nb.read({kind:'pageElement',id:args.pageID,elementID:args.elementID}); await emit(s.data);"},
  readMany:{input:z.object({queries:z.array(query).min(1).max(128),expectedCursor:text.optional()}).strict(),returns:"Snapshot<tuple> and coverages[] for the same ordered queries, captured in one WAL snapshot with a canonical merged basis. Each coverages[i].next continues that query. Conflicting basis versions cannot be merged.",example:"const s=await nb.readMany({queries:[{kind:'workspaceHeader'},{kind:'presence'}]}); await emit(s.data);"},
  board:{input:z.object({id:id.optional(),bounds:sceneBoundsSchema.optional(),limit:z.number().int().min(1).max(128).optional(),pinnedIDs:z.array(id).optional()}).strict(),returns:"Snapshot<SceneWindow>: data has header, boards, boardContentRevisions, items, totalMatches and truncated. basis includes the board and catalogue. Defaults to published viewport. For exhaustive spatial traversal use read scenePaintOrder.",example:"const scene=await nb.board({}); await emit(scene);",old:["notebook_read_board"]},
  notebook:{input:z.object({id,pageIndex:z.number().int().nonnegative().optional(),limit:z.number().int().min(1).max(4).optional(),visibleRoot:text.optional(),next:text.optional()}).strict(),returns:"Snapshot<PageDirectory>: data.header has item/visibleRoot; data.pages carries positions and versions. coverage.next continues through read({kind:'notebookDirectory',next}). Cover uses scenePaintOrder with coverID.",example:"await emit(await nb.notebook({id:args.notebookID,limit:4}));",old:["notebook_read_notebook"]},
  page:{input:z.object({id:id.optional(),elementID:text.optional()}).strict(),returns:"Snapshot<PageDocument> or Snapshot<PageElementRead|null> with elementID. A full page is explicit; one element never decodes unrelated bodies.",example:"const s=await nb.page({id:args.pageID,elementID:args.elementID}); await emit(s.data);",old:["notebook_read_page"]},
  document:{input:z.object({id:id.optional(),blockID:text.optional()}).strict(),returns:"Snapshot<DocumentDocument> or Snapshot<DocumentBlockRead|null> with blockID. Block content/state/source versions share one addressed read; no other blocks or states are decoded. Both include the document's content/state basis.",example:"const s=await nb.document({id:args.documentID,blockID:args.blockID}); await emit(s.data);",old:["notebook_read_document"]},
  context:{input:z.object({id:id.optional(),after:id.optional(),revision:text.optional(),limit:z.number().int().min(1).max(64).optional()}).strict(),returns:"Snapshot<ContextDirectory|ContextPage>. coverage.next continues via read of contexts/contextEntries; history has its own readCursor and never supplies fresh content versions.",example:"await emit(await nb.context({id:args.contextID,limit:8}));",old:["notebook_read_context"]},
  attention:{input:z.object({contextID:id,referenceID:id}).strict(),returns:"Snapshot<Attention>: data.status is source_pixels, source_pixels_unavailable or pending. data.reference/payload/artifact preserve the original sent question; basis has no fabricated current owner versions.",example:"const s=(await nb.attention(args)).data; await emit(s); if(s.artifact) await emitImage(s.artifact);",old:["notebook_read_attention"]},
  code:{input:z.union([z.object({id}).strict(),z.object({file:query.shape.file.unwrap(),after:id.optional(),limit:z.number().int().max(64).optional()}).strict()]),returns:"Snapshot<CodeAnnotation|null> with id; data.fragment preserves reviewed text and identity, data.ink has addressed annotations, basis contains content/ink versions. file form returns a bounded fragment collection. Use notebook://code/<fragment.id> for navigation.",example:"await emit(await nb.code({id:args.fragmentID}));",old:["notebook_read_code_notes"]},
  search:{input:z.object({query:text.min(1).max(500),limit:z.number().int().min(1).max(100).optional(),filters:z.object({kinds:z.array(z.enum(["item","page","document","spatial"])).min(1).max(4).optional(),target:targetSchema.optional()}).strict().optional(),next:text.max(16384).optional()}).strict(),returns:"Snapshot<SearchResults>: data.results and data.total; coverage.next continues the same normalized query/filters in stable source-kind/address order. Source commits cause search_cursor_stale; restart explicitly. Presence/run events do not invalidate it. No handwriting OCR is inferred.",example:"await emit(await nb.search({query:'Transformer',limit:10}));",old:["notebook_search"]},
  reference:{input:z.object({target:targetSchema,elementID:text.optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {revision}, source identity including composition geometry where applicable.",example:"await emit(await nb.reference({target:{kind:'page',id:args.pageID}}));"},
  referenceStatus:{input:z.object({reference:referenceSchema}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {status:current|changed|checking|review_required|target_missing,currentRevision?,fingerprint?}; strictly read-only. checking means prepare via render if pixels are needed.",example:"await emit(await nb.referenceStatus({reference:args.reference}));"},
  action:{input:z.object({actionID:id.optional(),actionVersion:text.optional(),next:text.optional(),contextID:id.optional(),limit:z.number().int().min(1).max(50).optional(),after:id.optional(),
    section:z.enum(["operations","revisions","changes","continuations","undo","snapshots"]).optional(),offset:z.number().int().nonnegative().optional(),pageSize:z.number().int().min(1).max(64).optional()}).strict(),returns:"Snapshot<ActionDetails> for actionID or a collection without it. Detail pages require actionVersion plus section/offset; ActionResult.next is version-bound and returns its changed page. Publication checks that exact version; it does not invent delivery/show confirmation.",example:"await emit(await nb.action({actionID:args.actionID,actionVersion:args.actionVersion,next:args.next}));",old:["notebook_action"]},
  render:{input:z.object({target:targetSchema,expectedRevision:text,region:frame.optional(),worldOrigin:worldPointSchema.optional(),pageIndex:z.number().int().nonnegative().optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {status:pending,request} or target render receipt with exact source and artifact. Retain the same owner/revision and retry after nb.wait. No camera movement.",example:"const r=(await nb.render(args)).data; await emit(r); if(r.artifact) await emitImage(r.artifact);",old:["notebook_render"]},
  pageMap:{input:z.object({id:id.optional(),drawingRevision:text.optional(),sinceDrawingRevision:text.optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {status,drawingRevision,map}; map.regions names exact final-pencil crops. A cold source returns pending request.",example:"await emit(await nb.pageMap({id:args.pageID}));",old:["notebook_page_map"]},
  pageImage:{input:z.object({id:id.optional(),drawingRevision:text.optional(),mode:z.enum(["faithful","ink"]).optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {status,drawingRevision,artifacts[]}; faithful pencil overview with grid, or ink-only.",example:"const r=(await nb.pageImage({id:args.pageID})).data; for(const a of r.artifacts??[]) await emitImage(a);",old:["notebook_render_page"]},
  regions:{input:z.object({id:id.optional(),drawingRevision:text,regionIDs:z.array(text).min(1).max(4),mode:z.enum(["faithful","ink"]).optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. {status,drawingRevision,artifacts[]} ordered exactly as requested regionIDs; an erased/stale region is refused.",example:"const r=(await nb.regions(args)).data; for(const a of r.artifacts??[]) await emitImage(a);",old:["notebook_render_region","notebook_render_regions"]},
  place:{input:z.object({target:targetSchema,expectedRevision:text,contextID:id.optional(),additionalOwners:z.array(targetSchema).max(32).optional(),worldOrigin:worldPointSchema.optional(),
    items:z.array(z.object({id:text,size:z.object({width:z.number().positive().max(2048),height:z.number().positive().max(2048)}).strict(),relativeTo:referenceSchema.optional(),relativeToID:text.optional(),direction:z.enum(["right","below","free"])}).strict()).min(1).max(32),
    movable:z.array(z.object({target:targetSchema,elementID:text.optional()}).strict()).max(32).optional()}).strict(),returns:"Snapshot<Placement> contains the proposal's exact basis and placements/moves. References/additionalOwners still control movement. Pending/full/budget failure produces no partial placement.",example:"const s=await nb.page({id:args.pageID}); await emit(await nb.place({target:{kind:'page',id:s.data.id},expectedRevision:s.basis.owners[0].revision,items:[{id:'note',size:{width:180,height:100},direction:'free'}]}));",old:["notebook_place"]},
  transaction:{input:z.object({key:text.min(1).max(120),action}).strict(),returns:"ActionResult {actionID,actionVersion,changed,basis,publication,next?}. base is a read basis or explicit array of bases; no expected array. Versions never refresh before a write. Missing components -> basis_incomplete, incompatible versions -> basis_conflict, wrong workspace -> basis_workspace_mismatch. Scope remains separate. Canonical small changed values and exact after digests are frozen in the native commit with effect.value. Large changed sets use action({actionID,actionVersion,next}). Retry never substitutes latest state or later undo.",example:"const s=await nb.page({id:args.pageID,elementID:args.elementID}); await emit(await nb.transaction('label',{base:s.basis,summary:'Подпись',operations:[{kind:'updateElement',target:{kind:'page',id:args.pageID},id:args.elementID,values:{graphic:{label:'Обратная связь'}}}]}));",old:["notebook_apply"]},
  undo:{input:z.object({key:text.min(1).max(120),actionID:id}).strict(),returns:"ActionResult for the undo's own immutable version. Later human changes remain preserved. Original ActionResult remains unchanged; detailed preserved addresses require actionID and this actionVersion.",example:"await emit(await nb.undo('undo-label',{actionID:args.actionID}));",old:["notebook_undo"]},
  point:{input:z.object({key:text.min(1).max(120),contextID:id.optional(),replyTo:id.optional(),references:z.array(referenceSchema.partial({id:true,revision:true})).min(1).max(32)}).strict(),returns:"Durable shared-context entry. Reply requires contextID and replyTo. Does not alter human camera/selection.",example:"await emit(await nb.point('source',{references:[{target:{kind:'page',id:args.pageID},label:'Рассмотренный лист'}]}));",old:["notebook_point"]},
  presentation:{input:z.object({id:id.optional()}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. Current iPad view capability/presence, or exact presentation receipt by ID.",example:"await emit(await nb.presentation({}));"},
  present:{input:z.object({key:text.min(1).max(120),view:z.object({deviceID:id,sessionID:id,sequence:z.number().int().nonnegative(),nonce:id}).strict(),steps:z.array(presentationStepSchema).min(1).max(12)}).strict(),returns:"Sent/playing/completed/interrupted receipt. Human contact interrupts; read presentation({id}) for actual shown state. No replay after reconnect.",example:"const view=(await nb.presentation({})).data; await emit(await nb.present('show',{view:view.view,steps:args.steps}));",old:["notebook_present"]},
  cancelPresentation:{input:z.object({key:text.min(1).max(120),id}).strict(),returns:"Native interruption receipt for the explicitly named presentation; does not change saved content.",example:"await emit(await nb.cancelPresentation('stop-show',{id:args.presentationID}));",old:["notebook_present"]},
  export:{input:z.object({key:text.min(1).max(120),documentID:id}).strict(),returns:"{status:queued,jobID,documentID,contentRevision}; job continues outside JS time in the markup App Sandbox, with at most two compiler slots and 120 seconds each. Pinned Tectonic 0.16.9 and the full offline TeX 2022 distribution support custom preambles/packages, including TikZ and siunitx. Embedded SVG (including inline SVG), PNG and JPEG are included; valid internal anchors and HTTP/HTTPS/mailto links remain active in the PDF. Missing internal links are visibly marked. No user-cache, external user-file or network image access. TeX <=4 MiB; at most 128 images, <=16 MiB combined source images and <=8 MiB prepared images; PDF <=16 MiB, PDF plus prepared images <=17 MiB. The native owner verifies the document revision before atomically publishing the complete package.",example:"await emit(await nb.export('pdf',{documentID:args.documentID}));",old:["notebook_export_document"]},
  exportStatus:{input:z.object({jobID:id}).strict(),returns:"Snapshot {data,basis,coverage,cursor}. Queued/running/saved/failed/interrupted job; saved receipt contains immutable texPath/pdfPath, PDF sha256, assets with their exact paths and hashes, and packageSHA256 covering TeX, PDF and every image. Keep the whole package to recompile TeX. Historical receipts without package metadata remain readable.",example:"await emit(await nb.exportStatus({jobID:args.jobID}));"},
  wait:{input:z.object({milliseconds:z.number().int().min(0).max(1000)}).strict(),returns:"null after bounded async wait; does not hold interpreter CPU or native writer.",example:"await nb.wait({milliseconds:100});"},
  id:{input:z.object({key:text.min(1).max(120)}).strict(),returns:"Stable UUID derived from run_id and key, without a write.",example:"const id=await nb.id('diagram'); await emit(id);"},
  emit:{input:z.object({value:z.json()}).strict(),returns:"Durable output event with sequence. Output is paginated; no silent truncation.",example:"await emit({answer:42});"},
  emitImage:{input:z.object({artifact:image}).strict(),returns:"Durable reference to exact native pixels, returned as MCP image content.",example:"const r=(await nb.render(args)).data; if(r.artifact) await emitImage(r.artifact);"},
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
const scene = await nb.board({id:args.boardID});
await emit(await nb.transaction('move-item', {
  summary:'Переместить выбранный предмет', additionalOwners:[owner],
  base:scene.basis,
  operations:[{kind:'moveItem',target,id:args.itemID,
    values:{center:{tileX:0,tileY:0,localX:100,localY:80}}}]
}));`;
const renameExample=`const owner = await nb.read({kind:'ownerBoard',id:args.itemID});
if (!owner.data) throw new Error('Item has no containing board');
await emit(await nb.transaction('rename-item', {
  summary:'Переименовать предмет', base:owner.basis,
  operations:[{kind:'renameItem',target:{kind:'board',id:owner.data},id:args.itemID,values:{title:args.title}}]
}));`;
const blockStateExample=`const d = await nb.document({id:args.documentID});
const target = {kind:'document',id:d.data.id};
await emit(await nb.transaction('set-program-state', {
  summary:'Обновить состояние программы',
  base:d.basis,
  operations:[{kind:'setBlockState',target,id:args.blockID,values:{state:args.state}}]
}));`;
const geometryScope:Partial<Record<z.infer<typeof operationSchema>["kind"],string>>={
  moveItem:"The operation target is the containing board. The moved subject is {kind:'cover',id:itemID,boardID:boardID}; declare that cover in action.additionalOwners when no source context covers it. Listing only the board is insufficient. A context reference to this notebook's page also covers its physical carrier.",
  stackItems:"Declare each existing item's {kind:'cover',id:itemID,boardID:target.id} in action.additionalOwners unless source references already cover all carriers.",
  updateElement:"Changing frame or worldOrigin of an existing element requires scope for that element. Declare operation.target in action.additionalOwners, or reference its elementID/a source region that intersects its current geometry. Source/style-only edits do not add a geometry requirement.",
  reorderElements:"Every existing named element needs source scope, or declare operation.target in action.additionalOwners. Elements created earlier in this same action are exempt.",
};
const creationOwner="Creation changes the containing board and root workspace catalogue. nb.board returns both in snapshot.basis. Pass base:snapshot.basis. Newly created owners require no invented version; Core retains the same in-transaction rules.";
const createDocumentExample="const s=await nb.board({}); const boardID=s.data.boardID; await emit(await nb.transaction('document',{summary:'Учебный документ',base:s.basis,operations:[{kind:'createDocument',target:{kind:'board',id:boardID},values:{title:'Пример',center:{tileX:0,tileY:0,localX:0,localY:0},paperSize:'a4',blocks:[{id:'intro',kind:'markdown',source:'# Введение'}]}}]}));";
const operationDetails=Object.fromEntries(operationSchema.options.map(schema=>{
  const name=schema.shape.kind.value;
  return [name,{name,description:operationDescriptions[name],input:z.toJSONSchema(schema,{reused:"ref"}),
    ...(name==="renameItem"?{owner:"Find the containing board with nb.read({kind:'ownerBoard',id:itemID}). Use its UUID in operation.target, and the item UUID in operation.id. Use the returned snapshot.basis; it contains the board and workspace catalogue. A title-only edit needs no geometry scope.",example:renameExample}:{}),
    ...(["createDocument","createNotebook","createBoard"].includes(name)?{owner:creationOwner,
      ...(name==="createDocument"?{example:createDocumentExample}:{} )}:{}),
    ...(name==="setBlockState"?{owner:"Use the document target and the block ID. ReadBasis from nb.document includes content and state versions; either stale value rejects the entire transaction. values.state replaces the block's full JSON state.",example:blockStateExample}:{}),
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
  base:d.basis,
  operations:[{kind:'insertBlock',target:{kind:'document',id:d.data.id},id:'counter',values:${JSON.stringify(interactiveBlock,null,2)}}]
}));`;
const terminalStatuses=["completed","failed","cancelled","interrupted"];
const polling="Resume with after_seq=next_seq while status is queued/running OR has_more=true. Stop only when status is completed/failed/cancelled/interrupted AND has_more=false. running + has_more=false is normal: the current output is drained, but the program can still emit or save effects.";
export const sdkInputs = Object.fromEntries(Object.entries(catalogue).map(([name,method])=>[name,method.input]));
export const sdkOutputs:Record<string,z.ZodType> = {
  ...Object.fromEntries(Object.entries(methodDataSchemas).map(([name,schema])=>[name,snapshotSchema(schema)])),
  ...effectResultSchemas,
  read:snapshotSchema(z.union(Object.values(readDataSchemas))),
  readMany:snapshotSchema(z.array(z.union(Object.values(readDataSchemas)))).extend({coverages:z.array(coverageSchema)}),
};
export const sdkReference = {
  apiVersion:2,
  methods:Object.fromEntries(Object.entries(catalogue).map(([name,value])=>[name,{...value,input:z.toJSONSchema(value.input,{reused:"ref"}),output:z.toJSONSchema(sdkOutputs[name]!,{reused:"ref"})}])),
  readData:Object.fromEntries(Object.entries(readDataSchemas).map(([kind,schema])=>[kind,z.toJSONSchema(schema,{reused:"ref"})])),
  common:{basis:z.toJSONSchema(readBasisSchema),coverage:z.toJSONSchema(coverageSchema),actionResult:z.toJSONSchema(actionResultSchema)},
  operations:{description:"Choose operation/<name> for one exact schema. transaction contains the complete atomic action schema with shared $defs.",
    items:Object.values(operationDetails).map(({name,description})=>({name,topic:`operation/${name}`,description}))},
  operationDetails,
  execution:{polling,terminalStatuses,
    languages:"start.language is javascript (default) or typescript; the language is never inferred and failed TS never falls back to JS. Both accept an async body with args, nb, emit and emitImage. TS uses the app's pinned TypeScript 7.0.2 CLI, strict/noEmitOnError and generated NotebookSDK declarations before the same QuickJS interpreter. No imports, triple-slash paths, user tsconfig, filesystem or network. Compiler/SDK identity is fixed at durable admission; retry attaches to the original source/language/args without recompilation, even after a compiler update. Diagnostics name notebook-user.ts source lines.",
    preparationLimits:"TS preparation runs outside the writer, on a separate compiler connection. Limits: source/JS 256 KiB, map 1 MiB, diagnostics 64 KiB, temporary files 4 MiB, sampled resident memory 512 MiB, sampled CPU 5 seconds, wall 10 seconds including XPC launch. The 30-second active-run deadline includes preparation. Cancellation closes the next-stage fence: late compiler output cannot start JS. Public MCP reply/output limits are unchanged.",
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
    graphic:"insertElement: {kind:'graphic',source:'',frame:{x:20,y:20,width:100,height:100},graphic:{shape:'ellipse',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},label:'+',representation:'geometry',visible:true,sourceInkIDs:[]}}. Native shapes: ellipse, rectangle, triangle, diamond, plus, connector. Triangle/diamond/rectangle may carry vertices: 3/4 convex ordered points {x,y} normalized to [0,1] in frame; omit or set null for the canonical outline. cornerRadius sets circular rounding in owner points (null or 0 is sharp); the contour clamps it to fit adjacent edges. Connector bendPosition (0..1, default 0.5) moves the bend along the endpoint axis, while bend moves it perpendicular. For a board add worldOrigin. updateElement accepts a graphic patch, e.g. {graphic:{label:'?'}}; sourceInkIDs cannot be patched. convertInkToElement uses the same payload with existing sourceInkIDs and requires inkRevision.",
    connector:"A graphic with shape:'connector' has connection:{start:{point:{x:0,y:0},binding:{elementID:'a',normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:false}},end:{point:{x:100,y:0},binding:{elementID:'b',normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:false}},bend:0,startArrowhead:'none',endArrowhead:'arrow',labelPosition:0.5}. Points are element-local; bindings address native nodes on the same owner. Moving nodes derives the connection without changing its authored frame. Missing or hidden bound nodes hide the link, never detach it. Patch connection fields independently, e.g. {graphic:{connection:{bend:40},label:'1:2'}}. Replace an endpoint with {point:{x:...,y:...}} to detach explicitly. Styles support stroke, strokeWidth and dash solid/dashed/dotted. Heads: none/arrow/triangle/square/dot/pipe/diamond/inverted/bar. Read page/board/boardElement returns graphicResolution:{state:'geometry',frame} or {state:'hidden'} or {state:'pending',dependencies}; frame is derived, while the authored element.frame and binding values remain unchanged. Hidden means this geometry is not shown, including an ink representation; it does not remove intent. Undo reports retained_dependency addresses for later links that protect earlier node creation/conversion.",
    nativeText:"insertElement on board: {kind:'nativeText',source:'Подпись',worldOrigin:{tileX:0,tileY:0,localX:0,localY:0},frame:{x:0,y:0,width:200,height:80},textStyle:{fontSize:24,weight:0.45,red:0.09,green:0.09,blue:0.08,alpha:1}}. For a cover omit worldOrigin and use cover-local frame coordinates. Omit textStyle to use native defaults.",
    interactive:interactiveExample
  }
};
