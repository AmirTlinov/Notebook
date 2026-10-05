import { McpServer } from "@modelcontextprotocol/server";
import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from "@modelcontextprotocol/ext-apps/server";
import * as z from "zod/v4";
import { dirname, join } from "node:path";
import { readFile } from "node:fs/promises";
import { BridgeError, defaultSocketPath, runBridge } from "./bridge.js";
import { appendInkStrokeSchema, inkStrokePointSchema, operationSchema } from "./actions.js";
import { sceneBoundsSchema, worldPointSchema } from "./spatial.js";

declare const NOTEBOOK_PANEL_HTML: string;
export const panelResourceURI = "ui://notebook/workspace.html";
export const panelTargetSchema = z.object({kind:z.enum(["board","page"]),id:z.uuid()}).strict();
export const panelAddressSchema = z.object({
  workspaceID:z.uuid(),target:panelTargetSchema,socketKey:z.string().regex(/^[a-f0-9]{24}$/),
}).strict();
export const panelViewSchema=z.object({
  viewport:z.object({x:z.number().min(1).max(2048),y:z.number().min(1).max(2048)}).strict(),
  pixelScale:z.number().min(.5).max(4),
  camera:z.object({center:worldPointSchema,scale:z.number().min(.0125).max(4)}).strict().optional(),
}).strict().refine(view=>view.viewport.x*view.viewport.y*view.pixelScale**2<=16_777_216.000001,
  "The panel view exceeds its native pixel budget.");
const panelSourceSchema=z.object({id:z.string().min(1).max(120),
  page:z.record(z.string(),z.json()).optional(),spatial:z.record(z.string(),z.json()).optional(),
  placements:z.array(z.record(z.string(),z.json())).optional(),
}).strict();
const panelOperationSchema=z.discriminatedUnion('kind',[
  appendInkStrokeSchema.extend({values:appendInkStrokeSchema.shape.values.extend({
    points:z.array(inkStrokePointSchema.extend({x:z.number().finite(),y:z.number().finite(),
      width:z.number().finite().positive().optional()})).min(1).max(65_536),
    width:z.number().finite().positive().optional(),
  })}),...operationSchema.options.filter(schema=>schema.shape.kind.value!=='appendInkStroke'),
]);
export const panelEditSchema=panelAddressSchema.extend({
  actionID:z.uuid(),summary:z.string().min(1).max(1000),
  operations:z.array(panelOperationSchema).min(1).max(32),sources:z.array(panelSourceSchema).max(64),
}).strict().refine(edit=>edit.operations.some(op=>op.kind==='appendInkStroke')
  ? edit.operations.length===1&&edit.sources.length===0 : edit.sources.length>0,
  'A pen contact appends one stroke without element sources; other edits retain their captured sources.');

type Value=Record<string,unknown>;
type Address=z.infer<typeof panelAddressSchema>;

/** A panel binds the admitted workspace socket; switching another window cannot redirect it. */
export function panelSocket(address:Pick<Address,"socketKey">,initialSocket=defaultSocketPath()):string {
  return join(dirname(initialSocket),`${address.socketKey}.sock`);
}

async function result(operation:()=>Promise<Value>,appearance=false) {
  try {
    const value=await operation();
    const text=appearance?{workspaceID:value.workspaceID,target:value.target,cursor:value.cursor,
      status:(value.appearance as Value|undefined)?.status??"ready"}:value;
    return {content:[{type:"text" as const,text:JSON.stringify(text)}],structuredContent:value};
  } catch(cause) {
    const value=cause instanceof BridgeError ? {...cause.detail,status:"error"}
      :{status:"error",code:"panel_failed",message:cause instanceof Error?cause.message:String(cause)};
    return {isError:true,content:[{type:"text" as const,text:JSON.stringify(value)}],structuredContent:value};
  }
}

export function registerNotebookPanel(server:McpServer,socketPath:string,html?:string,bootstrapRuntime?:()=>Promise<Value>) {
  const appMetadata={ui:{resourceUri:panelResourceURI,visibility:["app"]}};
  registerAppResource(server,"Notebook workspace",panelResourceURI,{},async()=>({contents:[{
    uri:panelResourceURI,mimeType:RESOURCE_MIME_TYPE,
    text:html??(typeof NOTEBOOK_PANEL_HTML!=="undefined"?NOTEBOOK_PANEL_HTML
      :await readFile(new URL("../../.build/notebook-panel.html",import.meta.url),"utf8")),
    _meta:{ui:{csp:{connectDomains:[],resourceDomains:["blob:"]},prefersBorder:false},
      "openai/ui":{availableDisplayModes:["fullscreen"],preferredDisplayMode:"fullscreen"}},
  }]}));
  registerAppTool(server,"notebook_open",{
    title:"Notebook",
    description:"Open the real Notebook workspace for human and agent collaboration. The plugin runtime owns saved material. Pass an exact board/page target when known; omitted target follows the admitted Notebook focus. The panel keeps its own camera and selection and never changes the iPad camera. With no selected workspace, choose or create one inside the panel.",
    inputSchema:z.object({target:panelTargetSchema.optional(),bounds:sceneBoundsSchema.optional()}).strict(),
    annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},
    _meta:{ui:{resourceUri:panelResourceURI},"openai/ui":{entrypoints:[{type:"thread"},{type:"global"}]}},
  },input=>result(async()=>{
    const runtime=bootstrapRuntime?await bootstrapRuntime():await runBridge<Value>(socketPath,{command:"runtimeStatus"});
    if(runtime.state!=="ready")return {runtime};
    return readRuntimePanel(runtime,input,socketPath);
  }));
  registerAppTool(server,"notebook_panel_workspace",{
    title:"Choose a Notebook workspace",
    description:"Read, select, create or rename the personal workspace through the plugin runtime. Accepted edits retain their original workspace owner.",
    inputSchema:z.object({action:z.enum(["list","create","select","rename","retry"]),id:z.uuid().optional(),name:z.string().trim().min(1).max(200).optional()}).strict(),
    annotations:{readOnlyHint:false,destructiveHint:false,openWorldHint:false},_meta:appMetadata,
  },request=>result(async()=>{
    if(bootstrapRuntime&&["list","retry"].includes(request.action))await bootstrapRuntime();
    const value=await runBridge<Value>(socketPath,{command:"runtimeWorkspace",runtimeWorkspace:request});
    if(["create","select","retry"].includes(request.action)&&(value.status as Value)?.state==="ready"&&!value.error){
      value.snapshot=await readRuntimePanel(value.status as Value,{},socketPath);
    }
    return value;
  }));
  registerAppTool(server,"notebook_panel_presentation",{
    title:"Prepare this Notebook view",
    description:"Read native world tiles and captured source geometry for this panel. Reuse immutable assets already held by the panel; Notebook preserves ink, physical covers and painter order without changing any device camera.",
    inputSchema:panelAddressSchema.extend({appearance:panelViewSchema,knownCursor:z.string().optional(),knownRequestID:z.uuid().optional(),
      knownAssets:z.array(z.uuid()).max(96).optional(),includeFitBounds:z.boolean().optional()}).strict(),
    annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},_meta:appMetadata,
  },({socketKey,...request})=>result(()=>runBridge<Value>(panelSocket({...request,socketKey},socketPath),
    {command:"panelPresentation",panelPresentation:request}),true));
  registerAppTool(server,"notebook_panel_edit",{
    title:"Save a human Notebook edit",
    description:"Apply the completed human gesture through Notebook native commands. A pen contact carries one appendInkStroke and sources:[]; element and card edits carry their exact captured sources. Reuse actionID and identical payload after an uncertain response. The native owner chooses authorship and validates the addressed surface.",
    inputSchema:panelEditSchema,
    annotations:{readOnlyHint:false,destructiveHint:true,openWorldHint:false,idempotentHint:true},_meta:appMetadata,
  },({socketKey,...request})=>result(()=>runBridge<Value>(panelSocket({...request,socketKey},socketPath),
    {command:"panelEdit",panelEdit:request})));
  registerAppTool(server,"notebook_panel_undo",{
    title:"Undo a human Notebook contribution",
    description:"Undo the admitted native history head while preserving subsequent contributions from other authors.",
    inputSchema:panelAddressSchema.extend({actionID:z.uuid()}).strict(),
    annotations:{readOnlyHint:false,destructiveHint:true,openWorldHint:false,idempotentHint:true},_meta:appMetadata,
  },({socketKey,...request})=>result(()=>runBridge<Value>(panelSocket({...request,socketKey},socketPath),
    {command:"panelUndo",panelUndo:request})));
}

/** Another panel can select a workspace between these two requests. The
 * captured endpoint and identity keep this initial read with its accepted owner. */
async function readRuntimePanel(status:Value,request:Value,socketPath:string):Promise<Value>{
  const address=panelAddressSchema.pick({workspaceID:true,socketKey:true}).parse({workspaceID:status.workspaceID,socketKey:status.socketKey});
  const snapshot=await runBridge<Value>(panelSocket(address,socketPath),
    {command:"panelRead",panelRead:{...request,workspaceID:address.workspaceID}});
  if(String(snapshot.workspaceID).toLowerCase()!==address.workspaceID.toLowerCase()||snapshot.socketKey!==address.socketKey){
    throw new BridgeError({code:"workspace_changed",message:"Notebook вернул другое пространство."});
  }
  return snapshot;
}
