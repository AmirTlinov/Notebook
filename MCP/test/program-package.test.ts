import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, writeFile, rm, open, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
// @ts-expect-error Authored file tooling is plain executable JavaScript.
import {prepareProgramPackage,canonicalProgramJSON,validProgramPath,partBytes} from '../skills/notebook/scripts/program-package.mjs';

test('file preparation hashes bounded parts and never embeds bytes in the request', async () => {
  const root = await mkdtemp(join(tmpdir(),'notebook-program-'));
  try {
    await writeFile(join(root,'main.js'),'export const answer=42;');
    const file=await open(join(root,'data.bin'),'w');
    try { await file.truncate(300*1024*1024); await file.write(Buffer.from([73]),0,1,300*1024*1024-1); }
    finally { await file.close(); }
    const request=await prepareProgramPackage({directory:root,javaScript:'main.js',files:['main.js','data.bin']});
    const data=request.package.files[0];
    assert.equal(data.byteCount,300*1024*1024);assert.equal(data.parts.length,75);
    assert.ok(data.parts.every((part:any)=>part.byteCount===partBytes));
    assert.equal(new Set(data.parts.map((part:any)=>part.sha256)).size,2);
    assert.equal(request.packageHash,createHash('sha256').update(canonicalProgramJSON(request.package)).digest('hex'));
    assert.ok(JSON.stringify(request).length<20000);assert.equal('data' in data,false);
    assert.deepEqual(await prepareProgramPackage({directory:root,javaScript:'main.js',files:['data.bin','main.js']}),request);
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('namespace, MIME, symlink escape and cancellation are rejected before staging', async () => {
  for(const path of ['../a.js','a/../b','a//b','a/./b','/a','a%2fb','a?x','a\\b',''])assert.equal(validProgramPath(path),false);
  const root=await mkdtemp(join(tmpdir(),'notebook-program-'));
  try {
    await writeFile(join(root,'main.js'),'export{}');
    await writeFile(join(root,'wrong.txt'),'export{}');
    await symlink('/etc/hosts',join(root,'outside.js'));
    for(const input of [
      {javaScript:'wrong.txt',files:['wrong.txt']},
      {javaScript:'main.js',files:['main.js','main.js']},
      {javaScript:'outside.js',files:['outside.js']},
      {javaScript:'../main.js',files:['../main.js']}
    ])await assert.rejects(prepareProgramPackage({directory:root,...input}));
    await assert.rejects(prepareProgramPackage({directory:root,javaScript:'main.js',files:['main.js']},{signal:AbortSignal.abort()}));
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('trusted import tool forwards only its typed local capability, outside QuickJS', async () => {
  const {createServer:createSocketServer}=await import('node:net');
  const {chmod}=await import('node:fs/promises');
  const {Client,InMemoryTransport}=await import('@modelcontextprotocol/client');
  const {createServer}=await import('../src/server.js');
  const root=await mkdtemp(join(tmpdir(),'notebook-import-ipc-')),path=join(root,'bridge.sock'),requests:any[]=[];
  const native=createSocketServer(socket=>{
    let bytes=Buffer.alloc(0);
    socket.on('data',part=>{
      bytes=Buffer.concat([bytes,Buffer.isBuffer(part)?part:Buffer.from(part)]);
      if(bytes.length<4||bytes.length<4+bytes.readUInt32BE(0))return;
      const envelope=JSON.parse(bytes.subarray(4).toString());requests.push(envelope.request);
      const value={status:'staging',packageHash:envelope.request.programImport.packageHash,stagedBytes:0,totalBytes:64*1024*1024};
      const body=Buffer.from(JSON.stringify({version:1,id:envelope.id,result:value})),length=Buffer.alloc(4);length.writeUInt32BE(body.length);
      socket.end(Buffer.concat([length,body]));
    });
  });
  const server=createServer(path),client=new Client({name:'program-import-contract',version:'1'});
  try {
    await chmod(root,0o700);await new Promise<void>(resolve=>native.listen(path,resolve));await chmod(path,0o600);
    const [c,s]=InMemoryTransport.createLinkedPair();await server.connect(s);await client.connect(c);
    const packageHash='a'.repeat(64);
    for(const op of ['start','status','cancel']) {
      const args={op,packageHash,...(op==='start'?{manifestPath:'/tmp/authored/import.json'}:{})};
      const result=await client.callTool({name:'notebook_import_program',arguments:args});
      assert.notEqual(result.isError,true);
      assert.deepEqual(requests.at(-1),{command:'importProgram',programImport:args});
      assert.equal((result.structuredContent as any).packageHash,packageHash);
    }
    const before=requests.length;
    const invalid=await client.callTool({name:'notebook_import_program',arguments:{op:'start',packageHash:'../outside',manifestPath:'/tmp/x'}});
    assert.equal(invalid.isError,true);assert.equal(requests.length,before);
  } finally {await client.close();await server.close();native.close();await rm(root,{recursive:true,force:true});}
});


test('program CLI prepares a descriptor and animation publishes only its staged identity', async()=>{
  const {execFileSync}=await import('node:child_process'),{readFile}=await import('node:fs/promises');
  const {fileURLToPath}=await import('node:url'),{randomUUID}=await import('node:crypto');
  const {operationSchema}=await import('../src/actions.js');
  const {makeRecipe}=await import(new URL('../skills/notebook/scripts/recipes.mjs',import.meta.url).href);
  const root=await mkdtemp(join(tmpdir(),'notebook-program-cli-'));
  try {
    await writeFile(join(root,'main.js'),'notebook.ready(Promise.resolve());');
    await writeFile(join(root,'input.json'),JSON.stringify({directory:'.',javaScript:'main.js',files:['main.js']}));
    const output=execFileSync(process.execPath,[fileURLToPath(new URL('../skills/notebook/scripts/prepare.mjs',import.meta.url)),
      'program',join(root,'input.json'),join(root,'prepared.json')],{encoding:'utf8'});
    const descriptor=JSON.parse(await readFile(join(root,'prepared.json'),'utf8'));
    assert.equal(JSON.parse(output).packageHash,descriptor.packageHash);
    for(const kind of ['page','board','document']) {
      const input={target:{kind,id:randomUUID()},programPackage:descriptor.packageHash,
        anchor:{tileX:0,tileY:0,localX:0,localY:0},title:'Large program'};
      const request=makeRecipe('animation',input);
      const op=request.args.operations[0];operationSchema.parse(op);
      assert.equal(op.values.programPackage,descriptor.packageHash);
      assert.equal(op.values.html,'');assert.equal(op.values.javaScript,'');
      if(kind!=='document')assert.equal(op.values.source,'');
      assert.ok(JSON.stringify(request.args).length<3000);
      assert.throws(()=>makeRecipe('animation',{...input,html:'<p>conflict</p>'}),/not both/);
    }
  } finally {await rm(root,{recursive:true,force:true});}
});
