import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,pageID,itemID,rootBoardID} from './fixture.js';
import {readDataSchemas,snapshotSchema,actionResultSchema} from '../src/sdk-results.js';

test('generated output contracts accept actual same-snapshot native content, bases and immutable action pages',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-sdk-v2-ipc-'));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
    const queries=[{kind:'workspaceHeader'},{kind:'itemHeaders'},{kind:'itemHeader',id:itemID},{kind:'itemLifecycle',id:itemID},
      {kind:'pageHeader',id:pageID},{kind:'page',id:pageID},{kind:'notebookDirectory',id:itemID},
      {kind:'boardItem',id:rootBoardID},{kind:'presence'},{kind:'selection'},{kind:'contexts'}];
    for(const query of queries) {
      const [result]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]});
      const schema=readDataSchemas[query.kind as keyof typeof readDataSchemas];
      const parsed=snapshotSchema(schema).safeParse(result);
      assert.equal(parsed.success,true,query.kind+': '+JSON.stringify(parsed));
      assert.equal(typeof result.cursor,'string'); assert.equal(result.values,undefined);
    }
    const [initial]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'pageHeader',id:pageID}]});
    const id=randomUUID(),target={kind:'page',id:pageID};
    const action={id,summary:'Canonical v2 result',references:[],expected:initial.basis.owners,
      operations:[{kind:'insertElement',target,id:'sdk-node',values:{kind:'graphic',source:'',frame:{x:10,y:20,width:100,height:100},
        graphic:{shape:'ellipse',style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},label:'Canonical',representation:'geometry',visible:true,sourceInkIDs:[]}}}]};
    const admission=await store.command<any>({command:'admitAction',action});
    const prepared=await store.command<any>({command:'prepareAction',actionID:id,fingerprint:admission.fingerprint});
    const result=await store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    assert.equal(actionResultSchema.safeParse(result).success,true,JSON.stringify(actionResultSchema.safeParse(result)));
    assert.equal(result.publication.saved,'confirmed');assert.equal(result.publication.shownOnIPad,'awaiting_display');
    const [selected]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'pageElement',id:pageID,elementID:'sdk-node'}]});
    assert.equal(snapshotSchema(readDataSchemas.pageElement).safeParse(selected).success,true,JSON.stringify(selected));
    assert.equal(selected.data.element.graphic.label,'Canonical');
    assert.notEqual(selected.basis.owners[0].revision,initial.basis.owners[0].revision);
    const undo=await store.command<any>({command:'undo',actionID:id});
    assert.equal(actionResultSchema.safeParse(undo).success,true,JSON.stringify(actionResultSchema.safeParse(undo)));
    assert.notEqual(undo.actionVersion,result.actionVersion);
    const historical=await store.command<any>({command:'actionDetails',readSnapshots:true,actionID:id,actionPage:{actionVersion:result.actionVersion}});
    assert.equal(historical.data.actionVersion,result.actionVersion);
    assert.equal(historical.data.receipt.undo,undefined);
  } finally { await stopFixture(root);await rm(root,{recursive:true,force:true}); }
});
