import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {sdkInputs} from '../src/sdk-contracts.js';
import {readDataSchemas,snapshotSchema,actionResultSchema} from '../src/sdk-results.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,rootBoardID,itemID} from './fixture.js';

for(const cover of [false,true]) test(`typed native text style survives addressed read, edit and undo on ${cover?'cover':'board'}`,async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-text-style-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root));
    const target=cover?{kind:'cover',id:itemID,boardID:rootBoardID}:{kind:'board',id:rootBoardID};
    const read=async(query:unknown)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
    const commit=async(base:any,operations:unknown[])=>{
      sdkInputs.transaction!.parse({key:'style-contract',action:{base,summary:'Native text style',additionalOwners:[target],operations}});
      const action={id:randomUUID(),summary:'Native text style',references:[],additionalOwners:[target],expected:base.owners,operations};
      const admission=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
      return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    };
    const initial=await read(cover?{kind:'boardItem',id:itemID}:{kind:'boardContentRevision',id:rootBoardID});
    const original={fontSize:42,weight:0.6,red:0.2,green:0.4,blue:0.8,alpha:0.75};
    await commit(initial.basis,[{kind:'insertElement',target,id:'native-label',values:{kind:'nativeText',source:'Original label',
      frame:{x:10,y:20,width:200,height:80},textStyle:original,
      ...(cover?{}:{worldOrigin:{tileX:0,tileY:0,localX:0,localY:0}})}}]);
    const addressed=()=>read({kind:'boardElement',id:rootBoardID,elementID:'native-label'});
    const snapshot=await addressed();
    assert.equal(snapshotSchema(readDataSchemas.boardElement).safeParse(snapshot).success,true);
    assert.deepEqual(snapshot.data.textStyle,original);
    const {textStyle:omitted,...withoutStyle}=snapshot.data;
    assert.equal(readDataSchemas.boardElement.safeParse(withoutStyle).success,false,'Native spatial reads always include their style');
    const changed={...snapshot.data.textStyle,fontSize:snapshot.data.textStyle.fontSize+4};
    const result=await commit(snapshot.basis,[{kind:'updateElement',target,id:'native-label',values:{textStyle:changed}}]);
    assert.equal(actionResultSchema.safeParse(result).success,true);
    assert.deepEqual((await addressed()).data.textStyle,changed);
    const undo=await store.command<any>({command:'undo',actionID:result.actionID});
    assert.equal(actionResultSchema.safeParse(undo).success,true);
    const restored=await addressed();
    assert.deepEqual(restored.data.textStyle,original);
    assert.equal(restored.data.source,'Original label');
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});
