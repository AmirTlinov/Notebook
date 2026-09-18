import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {methodDataSchemas,readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,pageID} from './fixture.js';

test('page vision output contracts retain the complete native cell, point, pixel and hash fields',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-vision-result-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root));
    const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'pageVisionReceipt',id:pageID}]});
    assert.ok(snapshot?.data);
    const receipt=snapshot.data,region=receipt.regions[0];
    assert.equal(receipt.pageID.toLowerCase(),pageID);
    assert.deepEqual(region.contentCells,{column:0,row:0,width:1,height:1});
    assert.equal(region.cropPoints.width,receipt.gridSpacing);
    assert.deepEqual(region.cropPixels,{x:0,y:0,width:52,height:52});
    assert.equal(region.inkPixelCount,1);
    assert.equal(Object.hasOwn(region,'region'),false);
    assert.deepEqual(snapshotSchema(readDataSchemas.pageVisionReceipt).parse(snapshot),snapshot);
    const ready={status:'ready',drawingRevision:`${receipt.drawingStamp.counter}@${receipt.drawingStamp.actor.toLowerCase()}`,map:receipt};
    assert.deepEqual(methodDataSchemas.pageMap.parse(ready),ready);

    for(const key of ['contentCells','cropCells','contentPoints','cropPoints','cropPixels','inkPixelCount','faithfulPNG_SHA256','inkPNG_SHA256']) {
      const incomplete={...region}; delete incomplete[key];
      assert.equal(readDataSchemas.pageVisionReceipt.safeParse({...receipt,regions:[incomplete]}).success,false,key);
    }
    for(const key of ['format','pageID','renderScale','gridSpacing','gridColumns','gridRows','pixelSize','occupiedCells','previewPNG_SHA256','inkPNG_SHA256']) {
      const incomplete={...receipt}; delete incomplete[key];
      assert.equal(readDataSchemas.pageVisionReceipt.safeParse(incomplete).success,false,key);
    }

    // Native Codable omits nil properties; only the missing whole receipt is null.
    const empty={...receipt,occupiedCells:[],regions:[]};
    delete empty.visibleInkBounds; delete empty.suppressedInkIDs;
    assert.deepEqual(readDataSchemas.pageVisionReceipt.parse(empty),empty);
    assert.equal(readDataSchemas.pageVisionReceipt.parse(null),null);
    assert.deepEqual(methodDataSchemas.pageMap.parse({status:'pending'}),{status:'pending'});
    assert.equal(methodDataSchemas.pageMap.safeParse({status:'ready',map:null}).success,false);
    for(const field of ['visibleInkBounds','suppressedInkIDs']) {
      assert.equal(readDataSchemas.pageVisionReceipt.safeParse({...empty,[field]:null}).success,false,field);
    }
    assert.equal(readDataSchemas.pageVisionReceipt.safeParse({...receipt,suppressedInkIDs:[pageID]}).success,true);
  } finally { await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});
