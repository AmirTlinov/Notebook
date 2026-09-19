import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {operationSchema} from '../src/actions.js';
// @ts-expect-error Authored file tooling is plain executable JavaScript.
import {canonicalProgramJSON} from '../skills/notebook/scripts/program-package.mjs';
// @ts-expect-error Authored file tooling is plain executable JavaScript.
import {readPortable,portableRequest,submitPortable} from '../skills/notebook/scripts/portable-document.mjs';
const hash=(value:string|Buffer)=>createHash('sha256').update(value).digest('hex');
async function fixture(t:any){
  const root=await mkdtemp(join(tmpdir(),'portable-test-'));t.after(()=>rm(root,{recursive:true,force:true}));
  const bytes=Buffer.from('throw Error("Author code must not execute during import")'),part={sha256:hash(bytes),byteCount:bytes.length};
  const value={format:1,module:true,javaScript:'main.js',files:[{path:'main.js',mimeType:'text/javascript',byteCount:bytes.length,parts:[part]}]},sha256=hash(canonicalProgramJSON(value));
  const portable={format:'NotebookPortable/1',cut:{document:{id:'d',paperSize:'a4',preamble:'',blocks:[{id:'scene',kind:'interactive',source:'',html:'',css:'',javaScript:'',programPackage:sha256,height:800,initialState:{phase:0}}]},state:{id:'d',records:[{id:'scene',value:{phase:0.625}}]}},packages:[{sha256,value}]};
  const path=join(root,'document.package');await writeFile(path,JSON.stringify(portable));await writeFile(join(root,'blob-'+part.sha256),bytes);
  return {root,path,portable,part,sha256};
}
test('portable import stages original parts then one ordinary transaction without executing author code',async t=>{
  const f=await fixture(t);
  (f.portable.cut.document.blocks as any[]).push({id:'text',kind:'markdown',source:'# Saved source',html:'',css:'',javaScript:'',initialState:null,height:400});
  await writeFile(f.path,JSON.stringify(f.portable));
  const prepared=await readPortable(f.path),request=portableRequest(prepared);
  assert.deepEqual(request,portableRequest(prepared));assert.equal(request.args.blocks[0].initialState.phase,0.625);
  const calls:string[]=[],transactions:any[]=[];
  const client={callTool:async({name,arguments:args}:any)=>{
    calls.push(name);
    if(name==='notebook_import_program'){
      assert.equal(args.op,'start');assert.equal(args.packageHash,f.sha256);
      const descriptor=JSON.parse(await readFile(args.manifestPath,'utf8'));
      assert.deepEqual(descriptor.sources,[{path:'main.js',partPaths:[join(f.root,'blob-'+f.part.sha256)]}]);
      assert.equal(descriptor.packageHash,hash(canonicalProgramJSON(descriptor.package)));
      return {structuredContent:{status:'ready'}};
    }
    assert.equal(name,'notebook_execute');assert.equal(args.op,'start');
    const nb={read:async(q:any)=>{assert.deepEqual(q,{kind:'workspaceHeader'});return {data:{rootBoardID:'00000000-0000-4000-8000-000000000001'}}},
      readMany:async(q:any)=>{assert.deepEqual(q.queries,[{kind:'workspaceHeader'},{kind:'boardContentRevision',id:'00000000-0000-4000-8000-000000000001'}]);return {basis:'fresh-basis'}},
      transaction:async(key:any,value:any)=>{transactions.push({key,...value});return {status:'accepted'}}};
    // Only the CLI's fixed import coordinator executes; imported JS stays data.
    const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
    const result=await new AsyncFunction('nb','args',args.code)(nb,args.args);
    return {structuredContent:{status:'completed',result}};
  }};
  const result=await submitPortable(client,f.path);
  assert.equal(result.status,'completed');assert.deepEqual(calls,['notebook_import_program','notebook_execute']);
  assert.equal(transactions.length,1);assert.equal(transactions[0].base,'fresh-basis');
  const op=operationSchema.parse(transactions[0].operations[0]);assert.equal(op.kind,'createDocument');assert.equal(op.id,request.args.documentID);
  const imported=op.values.blocks[0];assert.ok(imported);assert.equal(imported.kind,'interactive');
  assert.deepEqual(imported.initialState,{phase:0.625});assert.equal(imported.programPackage,f.sha256);
  assert.notEqual(op.id,f.portable.cut.document.id);
});
test('portable input rejects altered manifests, missing closure and symlinks before staging',async t=>{
  const f=await fixture(t);
  const link=join(f.root,'link.package');await symlink(f.path,link);await assert.rejects(readPortable(link));
  const firstPackage=f.portable.packages[0];assert.ok(firstPackage);
  const firstFile=firstPackage.value.files[0];assert.ok(firstFile);firstFile.path='../escape';await writeFile(f.path,JSON.stringify(f.portable));await assert.rejects(readPortable(f.path),/identity mismatch/);
  f.portable.packages=[];await writeFile(f.path,JSON.stringify(f.portable));await assert.rejects(readPortable(f.path),/Incomplete/);
});
test('explicit null saved state does not resurrect initialState; failed or cancelled staging creates no document',async t=>{
  const f=await fixture(t);(f.portable.cut.state.records[0] as any).value=null;await writeFile(f.path,JSON.stringify(f.portable));
  assert.equal(portableRequest(await readPortable(f.path)).args.blocks[0].initialState,null);
  const calls:string[]=[];const client={callTool:async({name}:any)=>{calls.push(name);return {structuredContent:{status:'error'}}}};
  await assert.rejects(submitPortable(client,f.path),/Program import/);assert.deepEqual(calls,['notebook_import_program']);
  const abort=new AbortController();abort.abort();await assert.rejects(submitPortable(client,f.path,abort.signal));assert.equal(calls.length,1);
});
test('one import identity survives admission timeout and drains queued output without replaying accepted work',async t=>{
  const f=await fixture(t),ops:any[]=[],replies=[
    {isError:true,structuredContent:{status:'error',code:'response_pending',after_seq:0}},
    {isError:true,structuredContent:{status:'error',code:'run_missing'}},
    {structuredContent:{status:'queued',next_seq:0,has_more:false}},
    {structuredContent:{status:'running',next_seq:2,has_more:false}},
    {structuredContent:{status:'completed',next_seq:4,has_more:true}},
    {structuredContent:{status:'completed',next_seq:5,has_more:false,result:{documentID:'imported'}}}];
  const client={callTool:async({name,arguments:args}:any)=>{
    if(name==='notebook_import_program')return {structuredContent:{status:'ready'}};
    ops.push(args);return replies.shift();
  }};
  assert.equal((await submitPortable(client,f.path)).result.documentID,'imported');
  assert.deepEqual(ops.map(r=>r.op),['start','resume','start','resume','resume','resume']);
  assert.deepEqual(ops[0],ops[2]);assert.equal(new Set(ops.map(r=>r.run_id)).size,1);
  assert.deepEqual(ops.filter(r=>r.op==='resume').map(r=>r.after_seq),[0,0,2,4]);
});
