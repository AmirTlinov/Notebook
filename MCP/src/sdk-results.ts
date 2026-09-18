import * as z from "zod/v4";
import {expectationSchema, targetSchema, coverTargetSchema, referenceSchema, graphicSchema, textStyleSchema, operationSchema} from "./actions.js";
import {worldPointSchema} from "./spatial.js";

const id=z.uuid(), text=z.string(), number=z.number(), json=z.json();
const object=<T extends z.ZodRawShape>(fields:T)=>z.object(fields).passthrough();
const stamp=object({counter:number,actor:id}), size=object({width:number,height:number});
const frame=object({x:number,y:number,width:number,height:number}), point=object({x:number,y:number});
const surface=object({kind:z.enum(["board","cover","page","codeFragment"]),ownerID:id});
export const readBasisSchema=z.object({workspaceID:id,owners:z.array(expectationSchema).max(1024)}).strict();
export const coverageSchema=z.object({complete:z.boolean(),next:text.optional()}).strict();
export const snapshotSchema=(data:z.ZodType)=>z.object({data,basis:readBasisSchema,coverage:coverageSchema,cursor:text}).strict();
const resolution=z.discriminatedUnion("state",[z.object({state:z.literal("geometry"),frame}).passthrough(),z.object({state:z.literal("hidden")}).strict(),z.object({state:z.literal("pending"),dependencies:z.array(text)}).strict()]);
const appearance=object({state:z.enum(["intact","partial","erased"]),sourceIsCompleteAppearance:z.boolean()});
const element=object({id:text,kind:z.enum(["markdown","web","graphic","nativeText"]),frame,source:text,html:text,css:text,javaScript:text,state:json,
  appearance:appearance.optional(),graphic:graphicSchema.optional(),graphicResolution:resolution.optional(),surface:surface.optional(),worldOrigin:worldPointSchema.optional(),textStyle:textStyleSchema.optional()});
const spatialElement=element.extend({textStyle:textStyleSchema});
const item=object({id,kind:z.enum(["notebook","document","board"]),title:text,firstPageID:id.optional(),pageCount:number});
const header=object({workspaceID:id,rootBoardID:id,stamp,itemCount:number,cursor:number,selectedItemID:id.optional(),selectedPageID:id.optional(),boardRevision:text.optional(),boardStamp:stamp.optional(),spatialInkStamp:stamp.optional()});
const contentHeader=object({target:targetSchema,contentStamp:stamp,stateStamp:stamp.optional(),inkStamp:stamp.optional(),size:size.optional()});
const fieldVersion=object({stamp,human:z.boolean(),observed:z.record(text,number)});
const block=object({id:text,kind:z.enum(["markdown","latex","interactive"]),source:text,html:text,css:text,javaScript:text,initialState:json,height:number});
const state=object({id:text,value:json,stamp});
const document=object({format:number,id,paperSize:z.enum(["a4","letter"]),preamble:text,blocks:z.array(block),contentStamp:stamp});
const documentState=object({format:number,id,records:z.array(state),stamp});
const page=object({format:number,id,size,elements:z.array(element),agentStamp:stamp,drawingStamp:stamp,drawingData:json});
const pageElement=object({header:contentHeader,element,appearance,graphicResolution:resolution.optional()}).nullable();
const documentBlock=object({documentID:id,contentStamp:stamp,stateStamp:stamp,sourceVersion:fieldVersion,stateVersion:fieldVersion.optional(),block,state:json.optional()}).nullable();
const inkSample=object({point,worldPoint:worldPointSchema.optional(),timeOffset:number,width:number,opacity:number,force:number,azimuth:number,altitude:number});
const inkElementTarget=object({elementID:text,frame,worldOrigin:worldPointSchema.optional()});
const pageInkMetadata={id,tool:z.enum(["pen","eraser"]),color:object({red:number,green:number,blue:number}),sequence:number,isActive:z.boolean()};
const pageInkActions=object({header:contentHeader,baseline:object({present:z.boolean(),actionCount:number}),
  actions:z.array(object(pageInkMetadata)),nextActionID:id.optional()});
const pageInkAction=object({header:contentHeader,action:object({...pageInkMetadata,samples:z.array(inkSample),
  elementTargets:z.array(inkElementTarget).optional()})}).nullable();
const inkAction=object({id,tool:z.enum(["pen","eraser"]),color:object({red:number,green:number,blue:number}),spans:z.array(object({surface,samples:z.array(inkSample),elementTargets:z.array(inkElementTarget).optional()})),stamp,isActive:z.boolean(),stateStamp:stamp});
const ink=object({format:number,actions:z.array(inkAction),stamp});
const board=object({id,board:object({format:number,elements:z.array(spatialElement),stamp,freeItems:z.array(object({itemID:id,center:worldPointSchema,zIndex:number,stamp})),stacks:z.array(object({id,center:worldPointSchema,zIndex:number,itemIDs:z.array(id),stamp}))})});
const scene=object({header,boardID:id,items:z.array(item),boards:z.array(board),boardContentRevisions:z.record(text,text),totalMatches:number,truncated:z.boolean()});
const presence=object({format:number,boardID:id,mode:z.enum(["board","cover","page","document"]),camera:object({center:worldPointSchema,scale:number}),viewport:point,
  selectedItemID:id.optional(),notebookPageID:id.optional(),focusedItemID:id.optional(),openProgress:number,documentPageIndex:number});
const position=object({itemID:id,pageID:id,index:number,visibleRoot:text,readCursor:text});
const directoryHeader=object({workspaceID:id,item,visibleRoot:text,selectedPageID:id.optional(),selectedPageIndex:number.optional(),readCursor:text});
const directory=object({header:directoryHeader,pages:z.array(object({position,size,drawingStamp:stamp,agentStamp:stamp})),nextIndex:number.optional()});
const entry=object({id,author:z.enum(["human","agent"]),references:z.array(referenceSchema),createdAt:number,text:text.optional(),stamp});
const contextSummary=object({id,firstEntry:entry.optional(),lastEntry:entry.optional()});
const contexts=object({contexts:z.array(contextSummary),nextContextID:id.optional(),readCursor:text});
const contextEntries=object({id,entries:z.array(entry),nextEntryID:id.optional(),readCursor:text});
const file=object({computer:id,project:text,root:text,path:text});
const codeFragment=object({id,file,sourceHash:text,utf16Offset:number,text,width:number,height:number,fontSize:number,stamp});
const code=object({fragment:codeFragment,ink}).nullable();
const path=z.array(z.union([object({field:object({_0:text})}),object({member:object({_0:text})}),object({order:z.object({})})]));
const publication=object({saved:z.literal("confirmed"),receivedByIPad:z.enum(["confirmed","awaiting_device"]),shownOnIPad:z.enum(["confirmed","awaiting_display","not_required"]),shownOnIPadReason:text.optional()});
const changed=z.discriminatedUnion("change",[
  object({file:text,path,change:z.enum(["updated","deleted"]),afterDigest:text.nullable(),value:json.optional(),valueOmitted:z.boolean().optional()}),
  z.object({change:z.literal("appendPage"),target:coverTargetSchema,pageID:id,item}).strict(),
  z.object({change:z.literal("deletedItem"),target:coverTargetSchema,item}).strict(),
  z.object({change:z.literal("restoreItem"),target:coverTargetSchema,item}).strict(),
  z.object({change:z.literal("removePage"),target:coverTargetSchema,pageID:id,item:item.optional()}).strict(),
]);
const lifecycleChange=z.discriminatedUnion("kind",[
  object({kind:z.literal("appendPage"),target:coverTargetSchema,pageID:id,beforeItem:item.optional(),afterItem:item}),
  object({kind:z.literal("deleteItem"),target:coverTargetSchema,beforeItem:item,afterItem:item.optional()}),
]);
const lifecycleUndoChange=z.discriminatedUnion("kind",[
  object({kind:z.literal("restoreItem"),target:coverTargetSchema,item}),
  object({kind:z.literal("removePage"),target:coverTargetSchema,pageID:id,item:item.optional()}),
]);
export const actionResultSchema=z.object({actionID:id,actionVersion:text,summary:text,basis:readBasisSchema,publication,
  changed:z.array(changed),changeCount:number,next:text.optional(),undo:object({restored:number,preservedCount:number,completedAt:number}).optional()}).strict();
const receipt=object({id,actionVersion:text.optional(),createdAt:number,action:object({summary:text,contextID:id.optional(),references:z.array(referenceSchema),operations:z.array(object({kind:text,target:targetSchema,id:text.optional(),frame:frame.optional()}))}),revisions:z.array(expectationSchema),changes:z.array(z.union([object({file:text,path}),changed])),
  lifecycleChanges:z.array(lifecycleChange).max(512).optional(),
  undo:object({restored:number,completedAt:number,
    preserved:z.array(z.union([object({file:text,path}),z.object({target:coverTargetSchema,reason:z.literal("lifecycle_owner_continued")}).strict()])),
    preservedLifecycle:z.array(coverTargetSchema).max(512).optional(),lifecycleChanges:z.array(lifecycleUndoChange).max(512).optional()}).optional()});
const details=object({actionVersion:text,receipt:receipt.optional(),publication:publication.optional(),actionID:id.optional(),page:object({section:text,offset:number,total:number,nextOffset:number.nullable(),items:z.array(json)}).optional(),
  pages:z.record(text,object({total:number,nextOffset:number.nullable()})).optional(),continuations:z.array(object({file:text,path,author:text})).optional(),nextActionID:id.nullable().optional()});
const artifact=object({kind:z.enum(["currentView","target","pageOverview","pageRegion","attention","scriptImage"]),id:id.optional(),contextID:id.optional(),referenceID:id.optional(),regionID:text.optional(),mode:text.optional(),expectedSHA256:text});
const renderRequest=object({id,target:targetSchema,sourceRevision:text,region:frame.optional(),worldOrigin:worldPointSchema.optional(),pageIndex:number.optional()});
const renderDiagnostics=z.array(object({kind:text,elementID:text.optional(),message:text}));
const render=object({status:text,request:renderRequest.optional(),id:id.optional(),artifact:artifact.optional(),pngSHA256:text.optional(),sourceRevision:text.optional(),diagnostics:renderDiagnostics.optional()});
const visionCell=object({column:number,row:number});
const visionCellFrame=object({column:number,row:number,width:number,height:number});
const visionRegion=object({id:text,contentCells:visionCellFrame,cropCells:visionCellFrame,
  contentPoints:frame,cropPoints:frame,cropPixels:frame,inkPixelCount:number,
  faithfulPNG_SHA256:text,inkPNG_SHA256:text});
const vision=object({format:number,pageID:id,drawingStamp:stamp,suppressedInkIDs:z.array(id).optional(),
  pageSize:size,renderScale:number,gridSpacing:number,gridColumns:number,gridRows:number,pixelSize:size,
  visibleInkBounds:frame.optional(),occupiedCells:z.array(visionCell),regions:z.array(visionRegion),
  previewPNG_SHA256:text,inkPNG_SHA256:text});
const viewReceipt=object({format:number,workspaceStamp:stamp,boardRevision:text,spatialInkStamp:stamp,presence,pngSHA256:text,renderViewport:point,surface:object({kind:text})});
const delivery=object({id,deviceID:id,actionVersion:text.optional(),revisions:z.array(expectationSchema),receivedAt:number,displayComplete:z.boolean()});
const attention=object({status:text,reference:referenceSchema.optional(),payload:json.optional(),artifact:artifact.optional(),pixelWidth:number.optional(),pixelHeight:number.optional(),code:text.optional()});
const selectionFields={id,surface:targetSchema,pageIndex:number.optional(),contextID:id.optional(),resolving:z.boolean()};
const selected=z.discriminatedUnion("kind",[
  object({...selectionFields,kind:z.literal("empty")}),
  object({...selectionFields,kind:z.literal("item"),itemID:id}),
  object({...selectionFields,kind:z.literal("element"),target:targetSchema,elementID:text}),
  object({...selectionFields,kind:z.literal("context")}),
  object({...selectionFields,kind:z.literal("reference"),reference:referenceSchema})]);
const selection=z.discriminatedUnion("status",[
  object({status:z.literal("known"),deviceID:id,sessionID:id,generation:number,selection:selected}),
  object({status:z.literal("unknown"),deviceID:id.optional(),sessionID:id.optional(),generation:number.optional()})]);
const observation=object({mode:z.enum(["snapshot","delta"]).optional(),status:text.optional(),target:targetSchema.optional(),header:z.union([contentHeader,object({target:targetSchema,contentRevision:text})]).optional(),reset:text.optional(),through:text.optional(),
  objects:z.array(object({target:targetSchema,id:text,change:z.enum(["upsert","deleted","outOfScope"]),value:object({appearance:appearance.optional(),content:z.union([element,block]).optional(),state:json.optional(),graphicResolution:resolution.optional(),preview:text.optional()}).optional()})).optional(),
  containers:z.array(item).optional(),checkpoint:text.optional(),presence:presence.nullable().optional(),presenceGeneration:text.optional(),selection:selection.optional(),context:contexts.optional(),visual:object({status:text,receipt:viewReceipt.optional(),artifact:artifact.optional()}).optional()});
const runtime=object({status:text,updatedAt:number}).nullable();
const exportJob=object({status:z.enum(["missing","queued","running","saved","failed","interrupted"]),jobID:id.optional(),documentID:id.optional(),contentRevision:text.optional(),receipt:object({documentID:id,pdfPath:text,texPath:text,pdfSHA256:text,byteCount:number,log:text,packageSHA256:text.optional(),assets:z.array(object({path:text,sha256:text})).optional()}).optional(),error:json.optional()});
const presentation=object({status:text.optional(),id:id.optional(),view:object({deviceID:id,sessionID:id,sequence:number,nonce:id}).optional(),reason:text.optional()});
const search=object({results:z.array(object({id,target:targetSchema,elementID:text.optional(),title:text,path:z.array(text),preview:text,revision:text,reference:referenceSchema})),total:number});
export const readDataSchemas = {
  observation, workspaceHeader:header, itemHeaders:z.array(item), itemHeader:item.nullable(), itemLifecycle:object({item,target:coverTargetSchema,revision:text,bodyRecordCount:number.int().nonnegative()}).nullable(),
  workingSet:object({header,items:z.array(item),boards:z.array(board),pages:z.record(text,page),documents:z.record(text,document),states:z.record(text,documentState),ink}),
  sceneWindow:scene, scenePaintOrder:object({revision:text,entries:z.array(object({kind:text,id:text,zIndex:number})),nextCursor:text.nullable()}),
  page,pageHeader:contentHeader,pageElement,pageInkActions,pageInkAction,documentHeader:contentHeader,document,documentState,documentBlock,
  boardItem:board.nullable(),boardElement:spatialElement.nullable(),boardContentRevision:text.nullable(),ownerBoard:id.nullable(),
  notebookPages:object({header:directoryHeader,pages:z.array(object({position,document:page}))}),notebookDirectory:directory,notebookPosition:position.nullable(),
  spatialInk:ink,presence,selection,attentionEvidence:object({reference:referenceSchema,payload:json,image:object({sha256:text,pixelWidth:number,pixelHeight:number}).optional()}).nullable(),
  contexts,contextEntries,actions:z.array(receipt),currentViewReceipt:viewReceipt.nullable(),pageVisionReceipt:vision.nullable(),targetRenderReceipt:render.nullable(),
  renderRequests:z.array(renderRequest),delivery:z.array(delivery),actionSnapshots:z.array(object({request:renderRequest,pngSHA256:text.optional(),diagnostics:renderDiagnostics.optional()})),runtime,codeFragment:code,codeFragments:z.array(codeFragment),
};
export const methodDataSchemas = {
  observe:observation,page:z.union([page,pageElement]),document:z.union([document,documentBlock]),board:scene,notebook:directory,context:z.union([contexts,contextEntries]),
  attention,code:z.union([code,z.array(codeFragment)]),search,reference:object({target:targetSchema,revision:text}),referenceStatus:object({status:z.enum(["current","changed","checking","review_required","target_missing"]),currentRevision:text.optional(),fingerprint:text.optional()}),
  action:z.union([details,z.array(details),actionResultSchema]),render,pageMap:object({status:text,drawingRevision:text.optional(),map:vision.optional(),request:renderRequest.optional(),diagnostics:renderDiagnostics.optional(),delta:object({fromDrawingRevision:text,available:z.boolean(),unchangedRegionIDs:z.array(text),changedRegionIDs:z.array(text),removedRegionIDs:z.array(text)}).optional()}),
  pageImage:object({status:text,drawingRevision:text.optional(),artifacts:z.array(artifact).optional(),request:renderRequest.optional(),diagnostics:renderDiagnostics.optional()}),regions:object({status:text,drawingRevision:text.optional(),artifacts:z.array(artifact).optional(),request:renderRequest.optional(),diagnostics:renderDiagnostics.optional()}),
  prepareTldraw:z.object({items:z.array(z.object({id:text,parentID:text.optional(),type:text,label:text}).strict()),selectedIDs:z.array(text),
    elements:z.array(element),sourceIDs:z.record(text,text),diagnostics:z.array(z.object({severity:z.enum(["warning","error"]),code:text,sourceID:text.optional(),message:text}).strict()),size:point,canInsert:z.boolean()}).strict(),
  place:object({status:z.enum(["ready","snapshot_pending","placement_unavailable"]),target:targetSchema,placements:z.array(object({id:text,frame,worldOrigin:worldPointSchema.optional()})),moves:z.array(operationSchema),contextID:id.optional(),additionalOwners:z.array(targetSchema),sourceRevision:text,suggestion:text.optional(),renderRequest:renderRequest.optional()}),
  exportStatus:exportJob,presentation,
};
export const effectResultSchemas = {transaction:actionResultSchema,undo:actionResultSchema,point:object({id,entry}),present:presentation,cancelPresentation:presentation,export:exportJob,
  wait:z.null(),id,emit:object({sequence:number,kind:text,value:json,createdAt:number}),emitImage:object({sequence:number,kind:text,value:artifact,createdAt:number}),help:object({api_version:z.literal(2),topic:text.optional(),contract:json.optional()})};
