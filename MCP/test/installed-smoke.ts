import assert from "node:assert/strict";
import {dirname,join} from "node:path";
import {fileURLToPath} from "node:url";
import {Client} from "@modelcontextprotocol/client";
import {StdioClientTransport,getDefaultEnvironment} from "@modelcontextprotocol/client/stdio";

// Read-only installed-pair acceptance; writes belong to the isolated Mac/iPad
// acceptance environment. An app process alone does not prove IPC readiness.
const client=new Client({name:"notebook-installed-proof",version:"1"});
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const transport=new StdioClientTransport({command:join(dirname(fileURLToPath(import.meta.url)),"../run.sh"),env:environment,stderr:"pipe"});
try {
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools.map(t=>t.name).sort(),["notebook_context","notebook_execute"]);
  const help=await client.callTool({name:"notebook_context",arguments:{method:"help",args:{topic:"operations"}}});
  assert.notEqual(help.isError,true,JSON.stringify(help));assert.match(JSON.stringify(help.structuredContent),/"nativeText"/);
  const deadline=Date.now()+30_000;
  let result;
  do {
    result=await client.callTool({name:"notebook_context",arguments:{method:"observe"}});
    const context=(result.structuredContent as any)?.value;
    if(!result.isError&&context?.visual?.status==="ready"&&context?.connection?.status==="connected") break;
    await new Promise(resolve=>setTimeout(resolve,100));
  } while(Date.now()<deadline);
  assert.notEqual(result?.isError,true,JSON.stringify(result));
  assert.equal((result?.structuredContent as any)?.value?.visual?.status,"ready");
  assert.equal((result?.structuredContent as any)?.value?.connection?.status,"connected");
  assert.ok(result?.content.some(block=>block.type==="image"));
  console.log(JSON.stringify({status:"ready",scope:"installed read-only pair",observation:result?.structuredContent},null,2));
} finally {await client.close();}
