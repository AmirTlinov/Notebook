import assert from "node:assert/strict";
import {join} from "node:path";
import {homedir} from "node:os";
import {Client} from "@modelcontextprotocol/client";
import {StdioClientTransport,getDefaultEnvironment} from "@modelcontextprotocol/client/stdio";

// Read-only installed-pair acceptance; writes belong to the isolated Mac/iPad
// acceptance environment. An app process alone does not prove IPC readiness.
const client=new Client({name:"notebook-installed-proof",version:"1"});
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const app=process.env.NOTEBOOK_APP??join(homedir(),"Applications/Notebook.app");
const transport=new StdioClientTransport({command:join(app,"Contents/Resources/CodexRuntime/node"),
  args:[join(app,"Contents/Resources/NotebookTools/dist/index.mjs")],env:environment,stderr:"pipe"});
try {
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools.map(t=>t.name).sort(),["notebook_context","notebook_execute","notebook_import_document","notebook_import_document_resource","notebook_import_program","notebook_open","notebook_panel_edit","notebook_panel_read","notebook_panel_undo"]);
  const help=await client.callTool({name:"notebook_context",arguments:{method:"help",args:{topic:"operation/insertElement"}}});
  assert.notEqual(help.isError,true,JSON.stringify(help));assert.match(JSON.stringify(help.structuredContent),/"nativeText"/);
  const deadline=Date.now()+30_000;
  let result;
  do {
    result=await client.callTool({name:"notebook_context",arguments:{method:"observe",args:{includeImage:true}}});
    const context=(result.structuredContent as any)?.value?.data;
    if(!result.isError&&context?.visual?.status==="ready") break;
    await new Promise(resolve=>setTimeout(resolve,100));
  } while(Date.now()<deadline);
  assert.notEqual(result?.isError,true,JSON.stringify(result));
  assert.equal((result?.structuredContent as any)?.value?.data?.visual?.status,"ready");
  const runtime=await client.callTool({name:"notebook_context",arguments:{method:"read",args:{kind:"runtime"}}});
  assert.equal((runtime.structuredContent as any)?.value?.data?.status,"connected");
  assert.ok(result?.content.some(block=>block.type==="image"));
  console.log(JSON.stringify({status:"ready",scope:"installed read-only pair",observation:result?.structuredContent},null,2));
} finally {await client.close();}
