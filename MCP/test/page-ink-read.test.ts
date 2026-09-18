import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {sdkInputs,sdkOutputs} from '../src/sdk-contracts.js';
import {readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {BridgeError} from '../src/bridge.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,pageID} from './fixture.js';

test('public PAGE ink discovery supplies an addressed conversion basis without opaque drawing decoding',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-page-ink-sdk-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root)),target={kind:'page',id:pageID};
    const read=async(query:any)=>{
      sdkInputs.read!.parse(query);
      const [result]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]});
      const schema=(readDataSchemas as Record<string,any>)[query.kind];
      assert.equal(snapshotSchema(schema).safeParse(result).success,true,JSON.stringify(result));
      return result;
    };
    const commit=async(base:any,operations:unknown[])=>{
      sdkInputs.transaction!.parse({key:'ink-contract',action:{base,summary:'Addressed ink',additionalOwners:[target],operations}});
      const action={id:randomUUID(),summary:'Addressed ink',references:[],additionalOwners:[target],
        expected:base.owners,operations};
      const admitted=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admitted.fingerprint});
      return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admitted.fingerprint});
    };
    const initial=await read({kind:'pageHeader',id:pageID});
    const ids=[randomUUID(),randomUUID()].sort();
    await commit(initial.basis,ids.map((id,index)=>({kind:'appendInkStroke',target,id,values:{
      points:[{x:100+index*100,y:100},{x:160+index*100,y:160}]
    }})));
    const first=await read({kind:'pageInkActions',id:pageID,limit:1});
    assert.equal(first.data.actions.length,1);
    assert.equal(first.data.actions[0].id.toLowerCase(),ids[0]);
    assert.equal('samples' in first.data.actions[0],false);
    assert.deepEqual(first.data.baseline,{present:false,actionCount:0});
    assert.equal(first.coverage.complete,false);
    const second=await read({kind:'pageInkActions',next:first.coverage.next});
    assert.equal(second.data.actions[0].id.toLowerCase(),ids[1]);
    assert.equal(second.coverage.complete,true);
    const source=await read({kind:'pageInkAction',id:pageID,elementID:ids[0]});
    assert.equal(source.data.action.samples.length,2);
    assert.ok(source.basis.owners.some((owner:any)=>owner.target.kind==='page'&&owner.inkRevision));
    const converted=await commit(source.basis,[{kind:'convertInkToElement',target,id:'discovered-line',values:{
      kind:'graphic',source:'',frame:{x:100,y:100,width:60,height:60},
      graphic:{shape:'ellipse',label:'',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},
        representation:'geometry',visible:true,sourceInkIDs:[source.data.action.id]}
    }}]);
    assert.equal(sdkOutputs.transaction!.safeParse(converted).success,true);
    const same=await read({kind:'pageInkAction',id:pageID,elementID:ids[0]});
    assert.deepEqual(same.data.action,source.data.action,'Conversion never rewrites measured samples');
    await assert.rejects(commit(source.basis,[{kind:'appendInkStroke',target,id:randomUUID(),values:{
      points:[{x:1,y:1},{x:2,y:2}]
    }}]),(error:any)=>error instanceof BridgeError&&error.detail.code==='revision_conflict');
    const undo=await store.command<any>({command:'undo',actionID:converted.actionID});
    assert.equal(sdkOutputs.undo!.safeParse(undo).success,true);
    assert.deepEqual((await read({kind:'pageInkAction',id:pageID,elementID:ids[0]})).data.action,source.data.action);
    assert.equal((await read({kind:'pageInkAction',id:pageID,elementID:randomUUID()})).data,null);
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});
