import {McpServer} from '@modelcontextprotocol/server';
import {StdioServerTransport} from '@modelcontextprotocol/server/stdio';
import {registerAppResource,registerAppTool,RESOURCE_MIME_TYPE} from '@modelcontextprotocol/ext-apps/server';
declare const SURFACE_HOST_HTML:string;
const server=new McpServer({name:'Notebook surface verification',version:'1.0.0'});
const uri='ui://notebook/surface-host-verification.html';
registerAppResource(server,'Notebook surface verification',uri,{},async()=>({contents:[{
  uri,mimeType:RESOURCE_MIME_TYPE,text:SURFACE_HOST_HTML,
  _meta:{ui:{csp:{connectDomains:[],resourceDomains:['blob:'],frameDomains:['blob:']},prefersBorder:false},
    'openai/ui':{availableDisplayModes:['fullscreen'],preferredDisplayMode:'fullscreen'}},
}]}));
registerAppTool(server,'notebook_verify_surface_host',{
  title:'Notebook — проверка среды',description:'Verify the real Codex host for the Notebook Swift surface. Runs only bundled geometry, GPU and isolated HTML checks. No workspace access, file access, networking or content changes.',
  inputSchema:{},annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},_meta:{ui:{resourceUri:uri}},
},async()=>({content:[{type:'text' as const,text:'Notebook surface host verification. Open the panel to inspect each capability.'}]}));
await server.connect(new StdioServerTransport());
