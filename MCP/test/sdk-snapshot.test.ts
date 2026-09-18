import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,pageID,itemID,rootBoardID} from './fixture.js';
import {readDataSchemas,snapshotSchema,actionResultSchema,methodDataSchemas} from '../src/sdk-results.js';

test('generated output contracts accept actual same-snapshot native content, bases and immutable action pages',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-sdk-v2-ipc-'));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
    const queries=[{kind:'workspaceHeader'},{kind:'itemHeaders'},{kind:'itemHeader',id:itemID},{kind:'itemLifecycle',id:itemID},
      {kind:'pageHeader',id:pageID},{kind:'page',id:pageID},{kind:'notebookDirectory',id:itemID},
      {kind:'boardItem',id:rootBoardID},{kind:'boardItem',id:itemID},{kind:'presence'},{kind:'selection'},{kind:'contexts'}];
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

test('native lifecycle commit, retry and undo match the generated result and exact-version detail schemas',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-lifecycle-sdk-ipc-'));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
    const [extent]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'itemLifecycle',id:itemID}]});
    const id=randomUUID(),target=extent.data.target;
    const action={id,summary:'Append through public admission',references:[],expected:extent.basis.owners,
      additionalOwners:[target],operations:[{kind:'appendPage',target,values:{}}]};
    const admission=await store.command<any>({command:'admitAction',action});
    const prepared=await store.command<any>({command:'prepareAction',actionID:id,fingerprint:admission.fingerprint});
    const repeated=await store.command<any>({command:'prepareAction',actionID:id,fingerprint:admission.fingerprint});
    assert.equal(prepared.action.operations[0].id,repeated.action.operations[0].id);
    const commit={command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint};
    const result=await store.command<any>(commit);
    assert.equal(actionResultSchema.safeParse(result).success,true,JSON.stringify(result));
    const append=result.changed.find((change:any)=>change.change==='appendPage');
    assert.ok(append,'The frozen result must expose its compact append event');
    assert.equal(append.pageID.toLowerCase(),prepared.action.operations[0].id.toLowerCase());
    assert.equal(append.item.pageCount,extent.data.item.pageCount+1);
    assert.deepEqual(await store.command<any>(commit),result);
    const undo=await store.command<any>({command:'undo',actionID:id});
    assert.equal(actionResultSchema.safeParse(undo).success,true,JSON.stringify(undo));
    const removed=undo.changed.find((change:any)=>change.change==='removePage');
    assert.ok(removed,'Undo reports actual removal, not the original append');
    assert.equal(removed.pageID,append.pageID);
    assert.equal(removed.item.pageCount,extent.data.item.pageCount);
    assert.equal(undo.changed.some((change:any)=>change.change==='appendPage'),false);
    assert.deepEqual(await store.command<any>(commit),result,'A transaction replay after undo must retain its original immutable result');
    const historical=await store.command<any>({command:'actionDetails',readSnapshots:true,actionID:id,
      actionPage:{actionVersion:result.actionVersion,section:'changes'}});
    assert.equal(snapshotSchema(methodDataSchemas.action).safeParse(historical).success,true,JSON.stringify(historical));
    assert.equal(historical.data.actionVersion,result.actionVersion);
    assert.equal(historical.data.page.items.find((change:any)=>change.change==='appendPage')?.pageID,append.pageID);
    const latest=await store.command<any>({command:'actionDetails',readSnapshots:true,actionID:id,
      actionPage:{actionVersion:undo.actionVersion,section:'undo'}});
    assert.equal(latest.data.page.items.find((change:any)=>change.change==='removePage')?.pageID,append.pageID);
    const [current]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'itemHeader',id:itemID}]});
    assert.equal(current.data.pageCount,extent.data.item.pageCount);
  } finally { await stopFixture(root);await rm(root,{recursive:true,force:true}); }
});

test('native deletion and restoration expose compact headers and readable exact-version details',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-delete-sdk-ipc-'));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
    const read=async(query:unknown)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
    const commit=async(action:any)=>{
      const admission=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
      return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    };
    const board=await read({kind:'ownerBoard',id:itemID});
    await commit({id:randomUUID(),summary:'Keep a neighboring notebook',references:[],expected:board.basis.owners,
      operations:[{kind:'createNotebook',target:{kind:'board',id:board.data},values:{center:{tileX:0,tileY:0,localX:100,localY:100}}}]});
    const extent=await read({kind:'itemLifecycle',id:itemID}),target=extent.data.target,id=randomUUID();
    const result=await commit({id,summary:'Delete one observed item',references:[],expected:extent.basis.owners,additionalOwners:[target],
      operations:[{kind:'deleteItem',target,values:{}}]});
    assert.equal(actionResultSchema.safeParse(result).success,true,JSON.stringify(result));
    const deletion=result.changed.find((change:any)=>change.change==='deletedItem');
    assert.ok(deletion);
    assert.deepEqual(deletion.item,extent.data.item);
    assert.deepEqual(Object.keys(deletion).sort(),['change','item','target']);
    assert.equal((await read({kind:'itemHeader',id:itemID})).data,null);
    const undo=await store.command<any>({command:'undo',actionID:id});
    assert.equal(actionResultSchema.safeParse(undo).success,true,JSON.stringify(undo));
    const restored=undo.changed.find((change:any)=>change.change==='restoreItem');
    assert.ok(restored);
    assert.deepEqual(restored.item,extent.data.item);
    assert.equal(undo.changed.some((change:any)=>change.change==='deletedItem'),false);
    for(const version of [result.actionVersion,undo.actionVersion]) {
      const detail=await store.command<any>({command:'actionDetails',readSnapshots:true,actionID:id,actionPage:{actionVersion:version}});
      const parsed=snapshotSchema(methodDataSchemas.action).safeParse(detail);
      assert.equal(parsed.success,true,JSON.stringify(parsed));
      assert.equal(detail.data.actionVersion,version);
      assert.equal(detail.data.receipt.changes.some((change:any)=>change.change==='deletedItem'),true);
      if(version===undo.actionVersion) {
        assert.equal(detail.data.receipt.undo.lifecycleChanges[0].kind,'restoreItem');
        assert.equal(detail.data.receipt.undo.preservedCount,0);
      }
    }
    assert.deepEqual((await read({kind:'itemHeader',id:itemID})).data,extent.data.item);
    const page=await read({kind:'page',id:pageID});
    assert.equal(page.data.id.toLowerCase(),pageID);
    assert.deepEqual(page.data.size,{width:834,height:1194});
  } finally { await stopFixture(root);await rm(root,{recursive:true,force:true}); }
});

for (const kind of ['document','board'] as const) {
  test(`native ${kind} delete and undo preserve compact immutable public results`,async()=>{
    const root=await mkdtemp(join(tmpdir(),`notebook-${kind}-lifecycle-ipc-`));
    try {
      await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
      const read=async(query:unknown)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
      const commit=async(action:any)=>{
        const admission=await store.command<any>({command:'admitAction',action});
        const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
        const request={command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint};
        return {result:await store.command<any>(request),request};
      };
      const board=await read({kind:'ownerBoard',id:itemID}),id=randomUUID();
      await commit({id:randomUUID(),summary:`Create a ${kind}`,references:[],expected:board.basis.owners,
        operations:[{kind:kind==='document'?'createDocument':'createBoard',target:{kind:'board',id:board.data},id,
          values:{title:'Public lifecycle',center:{tileX:0,tileY:0,localX:100,localY:100},
            ...(kind==='document'?{paperSize:'a4'}:{})}}]});
      const extent=await read({kind:'itemLifecycle',id}),actionID=randomUUID();
      const {result,request}=await commit({id:actionID,summary:`Delete a ${kind}`,references:[],
        expected:extent.basis.owners,additionalOwners:[extent.data.target],
        operations:[{kind:'deleteItem',target:extent.data.target,values:{}}]});
      assert.equal(actionResultSchema.safeParse(result).success,true,JSON.stringify(result));
      assert.deepEqual(result.changed.find((change:any)=>change.change==='deletedItem')?.item,extent.data.item);
      assert.equal((await read({kind:'itemHeader',id})).data,null);
      assert.deepEqual(await store.command<any>(request),result);
      const undo=await store.command<any>({command:'undo',actionID});
      assert.equal(actionResultSchema.safeParse(undo).success,true,JSON.stringify(undo));
      assert.deepEqual(undo.changed.find((change:any)=>change.change==='restoreItem')?.item,extent.data.item);
      assert.notEqual(undo.actionVersion,result.actionVersion);
      assert.deepEqual((await read({kind:'itemHeader',id})).data,extent.data.item);
      assert.deepEqual(await store.command<any>(request),result,'Retry retains the original deletion after restoration');
      const detail=await store.command<any>({command:'actionDetails',readSnapshots:true,actionID,
        actionPage:{actionVersion:undo.actionVersion,section:'undo'}});
      assert.equal(snapshotSchema(methodDataSchemas.action).safeParse(detail).success,true,JSON.stringify(detail));
      assert.ok(detail.data.page.items.some((change:any)=>change.change==='restoreItem'));
    } finally { await stopFixture(root);await rm(root,{recursive:true,force:true}); }
  });
}

test('an addressed stack read supplies the containing board basis for public extraction and undo',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-stack-sdk-ipc-'));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root));
    const read=async(query:unknown)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
    const commit=async(action:any)=>{
      const admission=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
      return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    };
    const board=await read({kind:'ownerBoard',id:itemID}),other=randomUUID();
    const target={kind:'board',id:board.data},cover=(id:string)=>({kind:'cover',id,boardID:board.data});
    await commit({id:randomUUID(),summary:'Another stack member',references:[],expected:board.basis.owners,
      operations:[{kind:'createNotebook',target,id:other,values:{center:{tileX:0,tileY:0,localX:400,localY:100}}}]});
    const before=await read({kind:'ownerBoard',id:itemID});
    await commit({id:randomUUID(),summary:'Stack the two members',references:[],expected:before.basis.owners,
      additionalOwners:[cover(itemID),cover(other)],operations:[{kind:'stackItems',target,values:{itemIDs:[itemID,other]}}]});
    const stack=await read({kind:'boardItem',id:itemID});
    assert.equal(snapshotSchema(readDataSchemas.boardItem).safeParse(stack).success,true,JSON.stringify(stack));
    assert.equal(stack.data.id.toLowerCase(),board.data.toLowerCase());
    assert.ok(stack.basis.owners.some((owner:any)=>owner.target.kind==='board'&&owner.target.id===stack.data.id));
    assert.equal(stack.basis.owners.some((owner:any)=>owner.target.kind==='board'&&owner.target.id.toLowerCase()===itemID),false);
    const original=stack.data.board.stacks.find((value:any)=>value.itemIDs.some((id:string)=>id.toLowerCase()===itemID));
    assert.ok(original);
    const center={tileX:0,tileY:0,localX:900,localY:400},actionID=randomUUID();
    const moved=await commit({id:actionID,summary:'Extract one member',references:[],expected:stack.basis.owners,
      additionalOwners:[cover(itemID)],operations:[{kind:'moveItem',target,id:itemID,values:{center}}]});
    assert.equal(actionResultSchema.safeParse(moved).success,true,JSON.stringify(moved));
    const free=await read({kind:'boardItem',id:itemID});
    assert.deepEqual(free.data.board.freeItems.find((value:any)=>value.itemID.toLowerCase()===itemID)?.center,center);
    const undone=await store.command<any>({command:'undo',actionID});
    assert.equal(actionResultSchema.safeParse(undone).success,true,JSON.stringify(undone));
    const restored=await read({kind:'boardItem',id:itemID});
    assert.deepEqual(restored.data.board.stacks.find((value:any)=>value.id===original.id)?.itemIDs,original.itemIDs);
  } finally { await stopFixture(root);await rm(root,{recursive:true,force:true}); }
});
