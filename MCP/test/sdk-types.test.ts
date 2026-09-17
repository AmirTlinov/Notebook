import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {sdkReference,sdkInputs,sdkOutputs} from '../src/sdk-contracts.js';
import {executionInput,executionOutput} from '../src/server.js';
const run=promisify(execFile);

test('SDK v2 declarations type addressed reads, tuples, bases and results without a second hand-written API',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-sdk-types-'));
  try {
    const declarations=await readFile(new URL('../../Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts',import.meta.url),'utf8');
    assert.doesNotMatch(declarations,/\bany\b/);
    await writeFile(join(root,'notebook-sdk.d.ts'),declarations);
    await writeFile(join(root,'script.ts'),`async function program() {
      const input=args as {pageID:string; elementID:string; documentID:string};
      const s=await nb.page({id:input.pageID,elementID:input.elementID});
      if (!s.data) throw new Error('missing');
      const source:string=s.data.element.source;
      const d=await nb.document({id:input.documentID,blockID:'one'});
      if(d.data) { const kind:'markdown'|'latex'|'interactive'=d.data.block.kind; await emit(kind); }
      const batch=await nb.readMany({queries:[{kind:'pageHeader',id:input.pageID},{kind:'workspaceHeader'}]});
      const workspace:string=batch.data[1].workspaceID;
      const content:number=batch.data[0].contentStamp.counter;
      const result=await nb.transaction('label',{base:[s.basis,batch.basis],summary:'Label',operations:[{
        kind:'updateElement',target:{kind:'page',id:input.pageID},id:input.elementID,values:{graphic:{label:'Next'}}
      }]});
      const version:string=result.actionVersion;
      await emit({source,workspace,content,version,saved:result.publication.saved});
      // @ts-expect-error: a notebook read needs its identity
      await nb.notebook();
      // @ts-expect-error: v1 manual expected has been removed
      await nb.transaction('old',{summary:'old',expected:[],operations:[]});
      // @ts-expect-error: an addressed element is not the whole page
      const elements=s.data.elements;
      // @ts-expect-error: block kind is not arbitrary source text
      const wrong:number=d.data?.block.kind;
    }`);
    await writeFile(join(root,'tsconfig.json'),JSON.stringify({compilerOptions:{strict:true,noEmit:true,noEmitOnError:true,skipLibCheck:false,lib:['ES2023'],types:[],target:'ES2023',module:'esnext'},files:['notebook-sdk.d.ts','script.ts']}));
    const compiler=resolve('node_modules/.bin/tsc');
    await run(compiler,['--project',join(root,'tsconfig.json')],{maxBuffer:1024*1024});
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('every method has a generated output schema and start only accepts v2, defaulting to bounded completion wait',()=>{
  for(const [name,method] of Object.entries(sdkReference.methods)) assert.ok(method.output&&sdkInputs[name]&&sdkOutputs[name],name);
  const request={op:'start',run_id:'53d0ccbb-dc97-4911-ad2b-1b0f8ce4957d',api_version:2,code:'return 42'};
  const parsed=executionInput.parse(request);
  assert.equal(parsed.wait_ms,1000);
  assert.equal(executionInput.safeParse({...request,api_version:1}).success,false);
  assert.equal(executionOutput.safeParse({status:'completed',run_id:request.run_id,api_version:2,run_api_version:1,fingerprint:'historic',events:[],next_seq:0,has_more:false,result:42,error:null,effects:[],resume_semantics:'attach_only_no_replay'}).success,true);
});
