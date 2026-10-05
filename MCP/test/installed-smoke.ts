import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {Client} from "@modelcontextprotocol/client";
import {StdioClientTransport,getDefaultEnvironment} from "@modelcontextprotocol/client/stdio";

// Read through the installed plugin's actual launch route, including admission
// of its bundled runtime. No separately installed application is consulted.
const client=new Client({name:"notebook-installed-proof",version:"1"});
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const configured=spawnSync(process.env.CODEX_BIN??"codex",["mcp","get","notebook","--json"],{encoding:"utf8"});
assert.equal(configured.status,0,configured.stderr);
const connection=JSON.parse(configured.stdout);
assert.equal(connection.enabled,true);
assert.equal(connection.transport.type,"stdio");
const {command,args,env,env_vars,cwd}=connection.transport;
for(const name of env_vars??[])if(process.env[name]!==undefined)environment[name]=process.env[name]!;
const transport=new StdioClientTransport({command,args,env:{...environment,...env},...(cwd?{cwd}:{}),stderr:"pipe"});
try {
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools.map(t=>t.name).sort(),["notebook_context","notebook_execute","notebook_import_document","notebook_import_document_resource","notebook_import_program","notebook_open","notebook_panel_edit","notebook_panel_presentation","notebook_panel_undo","notebook_panel_workspace"]);
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
  console.log(JSON.stringify({status:"ready",scope:"installed plugin and paired workspace",image:"ready",runtime:"connected"},null,2));
} finally {await client.close();}
