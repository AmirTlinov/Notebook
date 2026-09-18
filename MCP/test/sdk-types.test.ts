import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {sdkReference,sdkInputs,sdkOutputs} from '../src/sdk-contracts.js';
import {executionInput,executionOutput} from '../src/server.js';
import {actionResultSchema} from '../src/sdk-results.js';
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
      const appearance:'intact'|'partial'|'erased'=s.data.appearance.state;
      const sourceIsPixels:boolean=s.data.appearance.sourceIsCompleteAppearance;
      const d=await nb.document({id:input.documentID,blockID:'one'});
      if(d.data) { const kind:'markdown'|'latex'|'interactive'=d.data.block.kind; await emit(kind); }
      const batch=await nb.readMany({queries:[{kind:'pageHeader',id:input.pageID},{kind:'workspaceHeader'}]});
      const workspace:string=batch.data[1].workspaceID;
      const content:number=batch.data[0].contentStamp.counter;
      const extent=await nb.read({kind:'itemLifecycle',id:input.documentID});
      if(extent.data) {
        const revision:string=extent.data.revision;
        const rows:number=extent.data.bodyRecordCount;
        const target:'cover'=extent.data.target.kind;
        const fence:string|undefined=extent.basis.owners[0].lifecycleRevision;
        await emit({revision,rows,target,fence});
        const appended=await nb.transaction('append-page',{base:extent.basis,summary:'Append',additionalOwners:[extent.data.target],
          operations:[{kind:'appendPage',target:extent.data.target,values:{}}]});
        for(const change of appended.changed) {
          if(change.change==='appendPage') {
            const page:string=change.pageID;
            const total:number=change.item.pageCount;
            const cover:'cover'=change.target.kind;
            await emit({page,total,cover});
          } else if(change.change==='deletedItem' || change.change==='restoreItem') {
            const title:string=change.item.title;
            await emit(title);
          } else if(change.change==='removePage') {
            const page:string=change.pageID;
            await emit(page);
          } else {
            const file:string=change.file;
            await emit(file);
          }
        }
        await nb.transaction('delete-item',{base:extent.basis,summary:'Delete',additionalOwners:[extent.data.target],
          operations:[{kind:'deleteItem',target:extent.data.target,values:{}}]});
        // @ts-expect-error: lifecycle writes require the physical cover, not a page
        await nb.transaction('wrong-owner',{base:extent.basis,summary:'Wrong',operations:[{kind:'appendPage',target:{kind:'page',id:input.pageID},values:{}}]});
        // @ts-expect-error: deleteItem has no second identity
        await nb.transaction('extra-id',{base:extent.basis,summary:'Wrong',operations:[{kind:'deleteItem',target:extent.data.target,id:input.pageID,values:{}}]});
        // @ts-expect-error: appendPage cannot replace size or any other catalogue field
        await nb.transaction('extra-values',{base:extent.basis,summary:'Wrong',operations:[{kind:'appendPage',target:extent.data.target,values:{size:{width:10,height:20}}}]});
      }
      const choice=await nb.read({kind:'selection'});
      const history=await nb.read({kind:'actions'});
      for(const receipt of history.data) {
        for(const target of receipt.undo?.preservedLifecycle??[]) {
          const kind:'cover'=target.kind;
          const parent:string=target.boardID;
          await emit({kind,parent});
        }
      }
      if(choice.data.status==='known') {
        const generation:number=choice.data.generation;
        if(choice.data.selection.kind==='element') {
          const exact:string=choice.data.selection.elementID;
          const owner:string=choice.data.selection.target.id;
          await emit({generation,exact,owner});
        }
      }
      const result=await nb.transaction('label',{base:[s.basis,batch.basis],summary:'Label',operations:[{
        kind:'updateElement',target:{kind:'page',id:input.pageID},id:input.elementID,values:{graphic:{label:'Next',connection:{routing:'elbow'}}}
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

test('ActionResult has discriminated compact lifecycle events and keeps field events intact',()=>{
  const id='53d0ccbb-dc97-4911-ad2b-1b0f8ce4957d',target={kind:'cover',id,boardID:id};
  const item={id,kind:'notebook',title:'Saved title',firstPageID:id,pageCount:2};
  const result={actionID:id,actionVersion:'a'.repeat(64),summary:'Frozen lifecycle',basis:{workspaceID:id,owners:[]},
    publication:{saved:'confirmed',receivedByIPad:'awaiting_device',shownOnIPad:'awaiting_display'},changeCount:1};
  const events=[{change:'updated',file:'page.json',path:[],afterDigest:'digest',value:'saved'},
    {change:'deleted',file:'page.json',path:[],afterDigest:null},
    {change:'appendPage',target,pageID:id,item},{change:'deletedItem',target,item},
    {change:'restoreItem',target,item},{change:'removePage',target,pageID:id,item}];
  for(const change of events) {
    const parsed=actionResultSchema.safeParse({...result,changed:[change]});
    assert.equal(parsed.success,true,JSON.stringify(parsed));
  }
  for(const change of [
    {change:'appendPage',target,item},{change:'deletedItem',target},{change:'restoreItem',target},
    {change:'removePage',target,item},{change:'deleteItem',target,item},
    {change:'appendPage',target:{kind:'page',id},pageID:id,item},
  ]) assert.equal(actionResultSchema.safeParse({...result,changed:[change]}).success,false,JSON.stringify(change));
});

test('every method has a generated output schema and start only accepts v2, defaulting to bounded completion wait',()=>{
  for(const [name,method] of Object.entries(sdkReference.methods)) assert.ok(method.output&&sdkInputs[name]&&sdkOutputs[name],name);
  const request={op:'start',run_id:'53d0ccbb-dc97-4911-ad2b-1b0f8ce4957d',api_version:2,code:'return 42'};
  const parsed=executionInput.parse(request);
  assert.equal(parsed.wait_ms,1000);
  assert.equal(executionInput.safeParse({...request,api_version:1}).success,false);
  assert.equal(executionOutput.safeParse({status:'completed',run_id:request.run_id,api_version:2,run_api_version:1,fingerprint:'historic',events:[],next_seq:0,has_more:false,result:42,error:null,effects:[],resume_semantics:'attach_only_no_replay'}).success,true);
});
