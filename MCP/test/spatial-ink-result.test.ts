import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureControl,fixtureSocket,stopFixture,appActor,itemID,rootBoardID} from './fixture.js';

test('native spatial ink reads retain optional eraser element targets in their original surface basis',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-spatial-ink-result-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root)),codeID=randomUUID();
    const stamp={counter:3,actor:appActor},origin={tileX:0,tileY:0,localX:0,localY:0};
    await fixtureControl(root,'codeFragment',{id:codeID,file:{computer:appActor,project:'fixture',root:'/fixture',path:'source.swift'},
      sourceHash:'a'.repeat(64),utf16Offset:0,text:'let value = 42',width:200,height:80,fontSize:16,stamp});
    const surfaces=[{kind:'board',ownerID:rootBoardID},{kind:'cover',ownerID:itemID},{kind:'codeFragment',ownerID:codeID}];
    const actions=surfaces.map((surface,index)=>({id:randomUUID(),tool:'eraser',color:{red:0,green:0,blue:0},
      stamp:{counter:index+1,actor:appActor},stateStamp:{counter:index+1,actor:appActor},isActive:true,
      spans:[{surface,samples:[{point:{x:20,y:30},...(surface.kind==='board'?{worldPoint:{...origin,localX:20,localY:30}}:{}),
        timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:1}],
        ...(surface.kind==='codeFragment'?{}:{elementTargets:[{elementID:'cut-element',frame:{x:10,y:20,width:100,height:80},
          ...(surface.kind==='board'?{worldOrigin:origin}:{})}]})}]}));
    await fixtureControl(root,'ink',{format:1,actions,stamp});
    for(const [index,surface] of surfaces.entries()) {
      const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'spatialInk',surfaces:[surface]}]});
      assert.equal(snapshot.data.actions.length,1);
      assert.equal(snapshot.data.actions[0].id.toLowerCase(),actions[index]!.id);
      assert.deepEqual(snapshotSchema(readDataSchemas.spatialInk).parse(snapshot),snapshot);
      const span=snapshot.data.actions[0].spans[0];
      assert.equal(span.surface.kind,surface.kind);
      assert.equal(span.surface.ownerID.toLowerCase(),surface.ownerID);
      assert.deepEqual(span.samples,actions[index]!.spans[0]!.samples);
      if(surface.kind==='codeFragment') assert.equal(Object.hasOwn(span,'elementTargets'),false);
      else assert.deepEqual(span.elementTargets,actions[index]!.spans[0]!.elementTargets);

      const withTargets=(elementTargets:unknown)=>({...snapshot.data,actions:[{...snapshot.data.actions[0],spans:[{...span,elementTargets}]}]});
      assert.equal(readDataSchemas.spatialInk.safeParse(withTargets(null)).success,false,'nil is omitted, not null');
      for(const malformed of [{elementID:'cut-element'},{elementID:12,frame:{x:1,y:2,width:3,height:4}},
        {elementID:'cut-element',frame:{x:1,y:2,width:3,height:4},worldOrigin:{x:1,y:2}}]) {
        assert.equal(readDataSchemas.spatialInk.safeParse(withTargets([malformed])).success,false,'targets have the native typed shape');
      }
    }
    const [annotation]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'codeFragment',id:codeID}]});
    assert.deepEqual(readDataSchemas.codeFragment.parse(annotation.data),annotation.data);
    assert.equal(Object.hasOwn(annotation.data.ink.actions[0].spans[0],'elementTargets'),false);
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});
