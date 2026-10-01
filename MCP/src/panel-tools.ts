import { McpServer } from "@modelcontextprotocol/server";
import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from "@modelcontextprotocol/ext-apps/server";
import * as z from "zod/v4";
import { dirname, join } from "node:path";
import { readFile } from "node:fs/promises";
import { BridgeError, defaultSocketPath, runBridge } from "./bridge.js";
import { operationSchema } from "./actions.js";
import { sceneBoundsSchema } from "./spatial.js";

declare const NOTEBOOK_PANEL_HTML: string;
export const panelResourceURI = "ui://notebook/workspace.html";
export const panelTargetSchema = z.object({kind:z.enum(["board","page"]),id:z.uuid()}).strict();
export const panelAddressSchema = z.object({
  workspaceID:z.uuid(),target:panelTargetSchema,socketKey:z.string().regex(/^[a-f0-9]{24}$/),
}).strict();
const panelSourceSchema=z.object({id:z.string().min(1).max(120),
  page:z.record(z.string(),z.json()).optional(),spatial:z.record(z.string(),z.json()).optional(),
}).strict();
export const panelEditSchema=panelAddressSchema.extend({
  actionID:z.uuid(),summary:z.string().min(1).max(1000),
  operations:z.array(operationSchema).min(1).max(32),sources:z.array(panelSourceSchema).min(1).max(64),
}).strict();

type Value=Record<string,unknown>;
type Address=z.infer<typeof panelAddressSchema>;

/** A panel binds the admitted workspace socket; switching another window cannot redirect it. */
export function panelSocket(address:Address,initialSocket=defaultSocketPath()):string {
  return join(dirname(initialSocket),`${address.socketKey}.sock`);
}

async function result(operation:()=>Promise<Value>) {
  try {
    const value=await operation();
    return {content:[{type:"text" as const,text:JSON.stringify(value)}],structuredContent:value};
  } catch(cause) {
    const value=cause instanceof BridgeError ? {...cause.detail,status:"error"}
      :{status:"error",code:"panel_failed",message:cause instanceof Error?cause.message:String(cause)};
    return {isError:true,content:[{type:"text" as const,text:JSON.stringify(value)}],structuredContent:value};
  }
}

export function registerNotebookPanel(server:McpServer,socketPath:string,html?:string) {
  const appMetadata={ui:{resourceUri:panelResourceURI,visibility:["app"]}};
  registerAppResource(server,"Notebook workspace",panelResourceURI,{},async()=>({contents:[{
    uri:panelResourceURI,mimeType:RESOURCE_MIME_TYPE,
    text:html??(typeof NOTEBOOK_PANEL_HTML!=="undefined"?NOTEBOOK_PANEL_HTML
      :await readFile(new URL("../../.build/notebook-panel.html",import.meta.url),"utf8")),
    _meta:{ui:{csp:{connectDomains:[],resourceDomains:[]},prefersBorder:false},
      "openai/ui":{availableDisplayModes:["fullscreen"],preferredDisplayMode:"fullscreen"}},
  }]}));
  registerAppTool(server,"notebook_open",{
    title:"Open Notebook beside this conversation",
    description:"Open the real Notebook workspace for human and agent collaboration. Uses the installed Mac runtime and existing saved material. Pass an exact board/page target when known; omitted target opens the root board. The panel keeps its own camera and selection and never changes the iPad camera. Other Notebook tools remain usable without opening the panel.",
    inputSchema:z.object({target:panelTargetSchema.optional(),bounds:sceneBoundsSchema.optional()}).strict(),
    annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},
    _meta:{ui:{resourceUri:panelResourceURI},"openai/ui":{entrypoints:[{type:"thread"},{type:"global"}]}},
  },input=>result(()=>runBridge<Value>(socketPath,{command:"panelRead",panelRead:input})));
  registerAppTool(server,"notebook_panel_read",{
    title:"Read this Notebook panel",
    description:"Read the panel's exact admitted workspace and surface without moving any device camera.",
    inputSchema:panelAddressSchema.extend({bounds:sceneBoundsSchema.optional(),knownCursor:z.string().optional()}).strict(),
    annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},_meta:appMetadata,
  },({socketKey,...request})=>result(()=>runBridge<Value>(panelSocket({...request,socketKey},socketPath),
    {command:"panelRead",panelRead:request})));
  registerAppTool(server,"notebook_panel_edit",{
    title:"Save a human Notebook edit",
    description:"Apply the completed human gesture through Notebook native commands with exact captured sources. Reuse actionID and identical payload after an uncertain response. The native owner chooses authorship and validates surface, sources and operations.",
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
