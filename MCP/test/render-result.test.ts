import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {methodDataSchemas,readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {revision} from '../src/domain.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureControl,fixtureSocket,stopFixture,pageID} from './fixture.js';

test('render and page vision errors preserve native structured diagnostics',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-render-result-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root)),target={kind:'page',id:pageID};
    const page=await store.readPage(pageID);
    const diagnostics=[{kind:'element_render_failed',elementID:'label',message:'Element rendering failed'},
      {kind:'renderer_unavailable',message:'Renderer unavailable'}];
    for(const command of ['render','pageVision'] as const) {
      const request=await store.command<{id:string}>({command,target,
        expectedRevision:revision(command==='render'?page.agentStamp:page.drawingStamp)});
      // The request is produced by Core. This existing isolated control decodes
      // TargetRenderReceipt and persists it through the native derivative owner.
      await fixtureControl(root,'targetReceipt',{request,status:'error',diagnostics,inkRegions:[],completedAt:0});
      const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,
        queries:[{kind:'targetRenderReceipt',id:request.id}]});
      assert.equal(snapshot.data.request.id.toLowerCase(),request.id.toLowerCase());
      assert.deepEqual(snapshot.data.diagnostics,diagnostics);
      assert.equal(Object.hasOwn(snapshot.data.diagnostics[1],'elementID'),false);
      assert.deepEqual(snapshotSchema(readDataSchemas.targetRenderReceipt).parse(snapshot),snapshot);
      assert.deepEqual(methodDataSchemas.render.parse(snapshot.data),snapshot.data);
      if(command==='pageVision') {
        // NotebookScriptReads.requestPageVision relays this native proof, not
        // strings or a second diagnostic model, to each cold page-image read.
        const failed={status:'error',code:'render_failed',request,diagnostics:snapshot.data.diagnostics};
        for(const kind of ['pageMap','pageImage','regions'] as const) {
          assert.deepEqual(methodDataSchemas[kind].parse(failed),failed);
        }
      }
    }
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});

test('all render diagnostic projections require kind and message and omit absent element identity',()=>{
  const projections=[methodDataSchemas.render,methodDataSchemas.pageMap,methodDataSchemas.pageImage,methodDataSchemas.regions];
  for(const schema of projections) {
    assert.deepEqual(schema.parse({status:'pending'}),{status:'pending'});
    assert.deepEqual(schema.parse({status:'ready',diagnostics:[]}),{status:'ready',diagnostics:[]});
    for(const diagnostic of ['failure',{kind:'failure'},{message:'failure'},
      {kind:'failure',message:'failure',elementID:null}]) {
      assert.equal(schema.safeParse({status:'error',diagnostics:[diagnostic]}).success,false,JSON.stringify(diagnostic));
    }
  }
});
