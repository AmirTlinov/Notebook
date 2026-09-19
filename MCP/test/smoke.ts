import assert from "node:assert/strict";
import {mkdtemp,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {Client,InMemoryTransport} from "@modelcontextprotocol/client";
import {createServer} from "../src/server.js";
import {runBridge} from "../src/bridge.js";
import {writeFixture,fixtureSocket,stopFixture} from "./fixture.js";

// A CLI test host owns Core IPC, not embedded XPC services. This smoke states
// that boundary explicitly; NotebookScriptServiceTests tests real execution.
const root=await mkdtemp(join(tmpdir(),"notebook-core-sidecar-smoke-"));
const client=new Client({name:"notebook-smoke",version:"1"});
try {
  await writeFixture(root);
  const socket=fixtureSocket(root),server=createServer(socket);
  const [c,s]=InMemoryTransport.createLinkedPair();await server.connect(s);await client.connect(c);
  assert.deepEqual((await client.listTools()).tools.map(t=>t.name).sort(),["notebook_context","notebook_execute","notebook_import_program"]);
  const read=await runBridge<{cursor:string;values:unknown[]}>(socket,{command:"read",queries:[{kind:"workspaceHeader"},{kind:"presence"}]});
  assert.equal(read.values.length,2);
  const absent=await client.callTool({name:"notebook_context",arguments:{method:"help"}});
  assert.equal(absent.isError,true);
  assert.equal((absent.structuredContent as any).code,"script_owner_unavailable");
  console.log(JSON.stringify({status:"ready",scope:"two-tool registration + isolated Core IPC; native XPC is a separate test",cursor:read.cursor}));
  await server.close();
} finally {await client.close();await stopFixture(root);await rm(root,{recursive:true,force:true});}
