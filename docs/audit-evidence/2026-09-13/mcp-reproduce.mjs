import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer as createNetServer } from 'node:net';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

// Diagnostic reproducer for known failures, not a passing acceptance suite.
// All stores and sockets below are newly created temporary fixtures.
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const mcp = join(repo, 'MCP');
process.env.NOTEBOOK_IPC_TEST_HOST ??= join(
  execFileSync('swift', ['build', '--show-bin-path'], { cwd: repo, encoding: 'utf8' }).trim(),
  'notebook-ipc-test-host');
const fromMCP = path => import(pathToFileURL(join(mcp, path)).href);
const { Client } = await fromMCP('node_modules/@modelcontextprotocol/client/dist/index.mjs');
const { StdioClientTransport, getDefaultEnvironment } = await fromMCP('node_modules/@modelcontextprotocol/client/dist/stdio.mjs');
const { NotebookStore } = await fromMCP('src/store.ts');
const { runBridge } = await fromMCP('src/bridge.ts');
const { revision } = await fromMCP('src/domain.ts');
const { pageID, writeFixture, fixtureSocket, stopFixture } = await fromMCP('test/fixture.ts');
const outputDirectory = await mkdtemp(join(tmpdir(), 'notebook-mcp-audit-results-'));
const results = [];
function record(label, detail) { const result={label,...detail}; results.push(result); console.log(JSON.stringify(result)); }
async function withMCP(socketPath, body) {
  const client = new Client({name:'notebook-mcp-audit',version:'0.0.0'});
  const transport = new StdioClientTransport({command:join(mcp,'run.sh'),env:{...getDefaultEnvironment(),NOTEBOOK_SOCKET:socketPath},stderr:'pipe'});
  try { await client.connect(transport); return await body(client); } finally { await client.close(); }
}
const fakeRoot = await mkdtemp('/tmp/notebook-mcp-audit-attention-');
const fakeSocket = join(fakeRoot,'bridge.sock');
let withImage = false;
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO3ZfZkAAAAASUVORK5CYII=', 'base64');
const server = createNetServer({allowHalfOpen:true}, socket => {
 const chunks=[]; socket.on('data', c => chunks.push(c)); socket.on('end',()=>{
  const packet=JSON.parse(Buffer.concat(chunks).subarray(4));
  const source={id:randomUUID(),requestID:randomUUID(),reference:{target:{kind:'page',id:pageID}},payload:{kind:'page'},...(withImage ? {image:{png:png.toString('base64'),sha256:createHash('sha256').update(png).digest('hex'),pixelWidth:1,pixelHeight:1}} : {})};
  const bytes=Buffer.from(JSON.stringify({version:1,id:packet.id,result:{values:[source]}})); const prefix=Buffer.alloc(4);prefix.writeUInt32BE(bytes.length);socket.end(Buffer.concat([prefix,bytes]));
 });
});
await chmod(fakeRoot,0o700); await new Promise(r=>server.listen(fakeSocket,r)); await chmod(fakeSocket,0o600);
try {
 await withMCP(fakeSocket,async client=>{
  const listed=(await client.listTools()).tools;
  record('registered_surface',{count:listed.length,inputSchemaBytes:Buffer.byteLength(JSON.stringify(listed.map(t=>({name:t.name,inputSchema:t.inputSchema})))),allToolDefinitionBytes:Buffer.byteLength(JSON.stringify(listed)),tools:listed.map(t=>t.name)});
  for (const mode of [false,true]) { withImage=mode; const result=await client.callTool({name:'notebook_read_attention',arguments:{context_id:randomUUID(),reference_id:randomUUID()}});record('read_attention',{withImage:mode,isError:result.isError??false,content:result.content});assert.equal(result.isError,true); }
 });
} finally {await new Promise(r=>server.close(r));await rm(fakeRoot,{recursive:true,force:true});}
const root=await mkdtemp('/tmp/notebook-mcp-audit-core-');
try {
 await writeFixture(root);const socketPath=fixtureSocket(root),store=new NotebookStore(socketPath),target={kind:'page',id:pageID};
 const source=await runBridge(socketPath,{command:'reference',target});
 const ref={id:randomUUID(),target,region:{x:0,y:0,width:100,height:100},revision:source.revision,label:'cold region'};
 let result;try {result=await runBridge(socketPath,{command:'referenceStatus',reference:ref});}catch(error){result={error:error.detail??String(error)};}
 record('cold_regional_reference_status',{result,requests:await store.read({kind:'renderRequests'})});
 await withMCP(socketPath,async client=>{
  const call=(name,args)=>client.callTool({name,arguments:args});
  const apply=async(operations,actionID=randomUUID(),expected)=>{
   const input={action_id:actionID,summary:'Isolated MCP audit',expected:expected??[{target,revision:revision((await store.readPage(pageID)).agentStamp)}],operations};
   return {input,result:await call('notebook_apply',input)};
  };
  const frame={x:10,y:20,width:100,height:60};
  const insert=await apply([{kind:'insertElement',target,id:'md',values:{kind:'markdown',source:'Before',frame}}]);assert.notEqual(insert.result.isError,true,JSON.stringify(insert.result));
  const update=await apply([{kind:'updateElement',target,id:'md',values:{source:'After'}}]);assert.notEqual(update.result.isError,true,JSON.stringify(update.result));
  const remove=await apply([{kind:'removeElement',target,id:'md',values:{}}]);assert.notEqual(remove.result.isError,true,JSON.stringify(remove.result));
  const retry=await call('notebook_apply',update.input);
  record('same_action_retry_after_element_removed',{originalSaved:update.result.structuredContent?.status,requestID:update.input.action_id,retry});
  assert.equal(retry.structuredContent?.code,'action_id_conflict');
  for(let index=0;index<12;index++){
   const action=await apply([{kind:'insertElement',target,id:'n'+index,values:{kind:'markdown',source:'Action '+index,frame}}]);assert.notEqual(action.result.isError,true,JSON.stringify(action.result));
  }
  for(let attempt=1;attempt<=5;attempt++){
   const at=performance.now();const read=await call('notebook_action',{limit:50});record('read_actions_beyond_ipc_capacity',{attempt,milliseconds:Math.round(performance.now()-at),isError:read.isError??false,code:read.structuredContent?.code,returned:read.structuredContent?.actions?.length,content:read.isError?read.content:undefined});
  }
 });
}finally{await stopFixture(root);await rm(root,{recursive:true,force:true});}
await writeFile(join(outputDirectory, 'results.json'), JSON.stringify(results, null, 2));
console.log('Diagnostic results: ' + join(outputDirectory, 'results.json'));
