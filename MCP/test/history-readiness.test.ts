import assert from 'node:assert/strict';
import test from 'node:test';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Client,InMemoryTransport} from '@modelcontextprotocol/client';
import {BridgeError} from '../src/bridge.js';
import {readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureControl,fixtureSocket,stopFixture,rootBoardID} from './fixture.js';
import {createServer} from '../src/server.js';

type MetadataQuery={kind:'replicaInventory'|'historyPhysicalClosure';[key:string]:unknown};
type ReadinessInputVariant={
  additionalProperties:boolean;required:string[];
  properties:{operation:{const:string};requestID:{format?:string};deviceIDs?:{minItems?:number;maxItems?:number}};
};

async function withFixture(body:(store:NotebookStore,root:string)=>Promise<void>):Promise<void> {
  const root=await mkdtemp(join(tmpdir(),'notebook-history-readiness-ipc-'));
  try {await writeFixture(root);await body(new NotebookStore(fixtureSocket(root)),root);}
  finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
}

async function snapshot(store:NotebookStore,query:MetadataQuery):Promise<any> {
  const values=await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]});
  assert.equal(values.length,1);
  const value=values[0];assert.ok(value);
  assert.deepEqual(snapshotSchema(readDataSchemas[query.kind]).parse(value),value);
  assert.deepEqual(value.basis.owners,[]);
  assert.equal(value.data.cut.workspaceID,value.basis.workspaceID);
  assert.equal(value.data.cut.readCursor,value.cursor);
  assert.match(value.cursor,/^(0|[1-9][0-9]*)$/);
  assert.equal(value.data.jointReadiness,false);
  assert.equal(value.coverage.complete,value.data.complete);
  assert.equal(value.coverage.next,undefined);
  return value;
}

async function databaseFingerprint(root:string):Promise<Record<string,unknown>> {
  const result:Record<string,unknown>={};
  for(const name of ['notebook.sqlite','notebook.sqlite-wal']) {
    try {
      const bytes=await readFile(join(root,name));
      result[name]={byteCount:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};
    } catch(error) {
      if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;
      result[name]=null;
    }
  }
  assert.notEqual(result['notebook.sqlite'],null);
  return result;
}

function metadataOnly(value:any,privateBody:string):void {
  const proof=value.data.proof;
  assert.equal(proof.borrowedSnapshotID,value.data.cut.snapshotID);
  assert.equal(proof.workspaceID,value.data.cut.workspaceID);
  assert.equal(proof.transactionID,value.data.transactionID);
  assert.equal(proof.manifestHash,value.data.manifestHash);
  assert.equal(proof.manifest.hash,value.data.manifestHash);
  const declared=proof.declaredRecords;
  assert.ok(declared,'Every transaction needs its own all-record physical proof');
  for(const field of ['recordCount','removalCount','payloadBytes','dependencyCount','dependencyBytes']) {
    assert.equal(Number.isSafeInteger(declared[field]),true,field);
    assert.ok(declared[field]>=0,field);
  }
  assert.ok(declared.removalCount<=declared.recordCount);
  for(const field of ['recordSetHash','dependencySetHash']) {
    if(declared[field]!==undefined)assert.match(declared[field],/^[a-f0-9]{64}$/);
  }
  for(const owner of [value.data,proof,declared]) {
    for(const field of ['rawPayload','body','action','operations','actor','sourceOriginal','birthTransactionID','originalAuthorID']) {
      assert.equal(Object.hasOwn(owner,field),false,field);
    }
  }
  for(const blob of [proof.manifest,...proof.manifestParts]) {
    assert.deepEqual(Object.keys(blob).sort(),['byteCount','hash']);
    assert.match(blob.hash,/^[a-f0-9]{64}$/);
    assert.equal(Number.isSafeInteger(blob.byteCount),true);
  }
  for(const receipt of proof.receipts) {
    for(const field of ['rawPayload','body','action','operations','actor','birthTransactionID','originalAuthorID']) {
      assert.equal(Object.hasOwn(receipt,field),false,field);
    }
    for(const blob of [receipt.sourceOriginal.original,receipt.sourceOriginal.model,receipt.sourceOriginal.result]) {
      if(blob)assert.deepEqual(Object.keys(blob).sort(),['byteCount','hash']);
    }
  }
  assert.equal(JSON.stringify(value).includes(privateBody),false);
  assert.equal(Object.hasOwn(value.data,'migrationAuthority'),false);
  assert.equal(Object.hasOwn(value.data,'birthTransactionID'),false);
}

test('readonly replica and physical history snapshots keep exact cuts, bounded evidence and no portable continuation authority',async()=>{
  await withFixture(async(store,root)=>{
    const [directory]=await store.command<any[]>({command:'read',readSnapshots:true,
      queries:[{kind:'actionHistoryPreflight',limit:64}]});
    assert.ok(directory.data.transactions.length>0,'Core seed must retain an accepted occurrence');
    const zeroOccurrence=directory.data.transactions[0];
    const zeroQuery:MetadataQuery={kind:'historyPhysicalClosure',id:zeroOccurrence.transactionID,
      revision:zeroOccurrence.manifestHash};
    const zero=await snapshot(store,zeroQuery);
    assert.deepEqual(zero.data.proof.receipts,[],'Fixture creation has no collaboration receipt');
    const zeroRecords=zero.data.proof.declaredRecords;
    assert.deepEqual(zeroRecords.status,{authenticatedDeclaredClosure:{}});
    assert.ok(zeroRecords.recordCount>0,'Zero receipts must still authenticate the nonaction seed records');
    assert.match(zeroRecords.recordSetHash,/^[a-f0-9]{64}$/);
    assert.match(zeroRecords.dependencySetHash,/^[a-f0-9]{64}$/);
    assert.equal(zero.coverage.complete,true);

    const privateBody='private-history-body-'+randomUUID(),actionID=randomUUID();
    const [board]=await store.command<any[]>({command:'read',readSnapshots:true,
      queries:[{kind:'boardContentRevision',id:rootBoardID}]});
    const target={kind:'board',id:rootBoardID};
    const action={id:actionID,summary:'Metadata privacy fixture',references:[],additionalOwners:[target],
      expected:board.basis.owners,operations:[{kind:'insertElement',target,id:'private-history-label',
        values:{kind:'nativeText',source:privateBody,frame:{x:10,y:20,width:200,height:80},
          worldOrigin:{tileX:0,tileY:0,localX:0,localY:0},
          textStyle:{fontSize:42,weight:0.6,red:0.2,green:0.4,blue:0.8,alpha:0.75}}}]};
    const admission=await store.command<any>({command:'admitAction',action});
    const prepared=await store.command<any>({command:'prepareAction',actionID,fingerprint:admission.fingerprint});
    await store.command({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});

    await fixtureControl(root,'readQueries');
    const before=await databaseFingerprint(root);
    const cut=await snapshot(store,{kind:'replicaInventory'});
    assert.equal(cut.data.mode,'cut');
    assert.equal(cut.data.cut.readRevision,cut.cursor);
    assert.equal(cut.data.cut.databaseVersion,29);
    assert.equal(cut.data.cut.wireVersion,44);
    assert.equal(cut.data.cut.manifestVersion,26);
    assert.equal(cut.data.cut.controlObservation.scope,'reusedReaderConnection');
    assert.match(cut.data.cut.controlObservation.fixedScalarHash,/^[a-f0-9]{64}$/);
    const head=cut.data.cut.acceptedLocalPrefix;assert.ok(head);
    assert.match(head.sequence,/^[1-9][0-9]*$/);
    for(const section of ['endpoints','cloudAccounts','cloudPending','cloudReceipts']) {
      const page=await snapshot(store,{kind:'replicaInventory',replicaSection:section,limit:64});
      assert.equal(page.cursor,cut.cursor);
      assert.equal(page.data.mode,section);
      assert.ok(page.data.entries.length<=64);
      assert.equal(page.data.cut.controlObservation.fixedScalarHash,cut.data.cut.controlObservation.fixedScalarHash);
    }

    const pointQuery:MetadataQuery={kind:'historyPhysicalClosure',id:head.transactionID,revision:head.manifestHash,
      referenceID:actionID};
    const point=await snapshot(store,pointQuery);
    assert.equal(point.cursor,cut.cursor);
    assert.equal(point.data.proof.receipts.length,1);
    assert.equal(point.data.proof.receipts[0].id.toLowerCase(),actionID.toLowerCase());
    assert.deepEqual(point.data.proof.declaredRecords.status,{authenticatedDeclaredClosure:{}});
    assert.deepEqual(point.data.proof.receipts[0].status,{authenticatedDeclaredClosure:{}});
    assert.equal(point.coverage.complete,true);
    metadataOnly(point,privateBody);metadataOnly(zero,privateBody);
    const unknown=await snapshot(store,{...pointQuery,referenceID:randomUUID()});
    assert.equal(unknown.coverage.complete,false);
    assert.equal(unknown.data.proof.receipts[0].status.unproven._0,'rootAbsent');
    assert.equal(unknown.data.proof.receipts[0].sourceOriginal.status.unproven._0,'originalAnchorUnavailable');
    metadataOnly(unknown,privateBody);

    // Schemas preserve decimal metadata above JS's exact numeric range. This
    // representation check supplies no native cut or joint-readiness authority.
    const exact='9223372036854775807';
    const decimal={...cut.data,cut:{...cut.data.cut,readRevision:exact,readCursor:exact,
      acceptedLocalPrefix:{...head,sequence:exact}}};
    assert.deepEqual(readDataSchemas.replicaInventory.parse(decimal),decimal);
    for(const invalid of [{...cut.data,jointReadiness:true},{...cut.data,birthTransactionID:randomUUID()},
      {...cut.data,entries:Array.from({length:65},()=>({}))},
      {...cut.data,cut:{...cut.data.cut,readRevision:9}},
      {...cut.data,cut:{...cut.data.cut,controlObservation:{...cut.data.cut.controlObservation,fixedScalarHash:'BAD'}}}]) {
      assert.equal(readDataSchemas.replicaInventory.safeParse(invalid).success,false);
    }
    assert.equal(readDataSchemas.historyPhysicalClosure.safeParse({...point.data,manifestHash:'BAD'}).success,false);
    assert.equal(readDataSchemas.historyPhysicalClosure.safeParse({...point.data,jointReadiness:true}).success,false);

    const foreignScope={target:{kind:'workspace',id:randomUUID()}};
    const forged=(query:MetadataQuery)=>'nbread2:'+Buffer.from(JSON.stringify({
      workspaceID:cut.basis.workspaceID,cursor:cut.cursor,query})).toString('base64');
    for(const query of [
      {kind:'replicaInventory',id:randomUUID()}, {kind:'replicaInventory',scope:foreignScope},
      {kind:'replicaInventory',limit:65}, {kind:'replicaInventory',after:randomUUID()},
      {kind:'replicaInventory',revision:head.manifestHash}, {kind:'replicaInventory',next:'bad'},
      {kind:'replicaInventory',next:forged({kind:'replicaInventory'})},
      {...pointQuery,scope:foreignScope}, {...pointQuery,revision:'BAD'},
      {...pointQuery,revision:'0'.repeat(64)}, {...pointQuery,id:randomUUID()},
      {...pointQuery,limit:65}, {...pointQuery,next:'bad'}, {...pointQuery,next:forged(pointQuery)},
    ]) {
      await assert.rejects(store.command({command:'read',readSnapshots:true,queries:[query]}),
        error=>error instanceof BridgeError,'Unsupported scope/hash/page must refuse, not return complete evidence');
    }
    const finalCut=await snapshot(store,{kind:'replicaInventory'});
    assert.equal(finalCut.cursor,cut.cursor);
    assert.deepEqual(finalCut.data.cut.acceptedLocalPrefix,head);
    assert.equal(finalCut.data.cut.journalGenerationStatus,cut.data.cut.journalGenerationStatus);
    assert.equal(finalCut.data.cut.journalGeneration,cut.data.cut.journalGeneration);
    assert.deepEqual(await databaseFingerprint(root),before,'Readonly and refused calls cannot author DB/WAL data');
    const queries=await fixtureControl<string[]>(root,'readQueries');
    assert.ok(queries.length>0);
    assert.ok(queries.every(kind=>kind==='replicaInventory'||kind==='historyPhysicalClosure'));
  });
});

test('history readiness tool exposes strict attach shapes and reports the actual missing native coordination owner',async()=>{
  await withFixture(async(store,root)=>{
    let admissions=0;
    const server=createServer(store.socketPath,{bootstrapRuntime:async()=>{
      admissions++;return {fixture:'isolated-core-owner'};
    }}),client=new Client({name:'history-readiness-contract',version:'1'});
    try {
      const [caller,owner]=InMemoryTransport.createLinkedPair();await server.connect(owner);await client.connect(caller);
      const tools=(await client.listTools()).tools;
      const tool=tools.find(value=>value.name==='notebook_history_readiness');assert.ok(tool);
      assert.equal(tools.filter(value=>value.name==='notebook_history_readiness').length,1);
      assert.equal(tool.annotations?.readOnlyHint,false);assert.equal(tool.annotations?.destructiveHint,false);
      assert.equal(tool.annotations?.idempotentHint,true);assert.equal(tool.annotations?.openWorldHint,false);
      const schema=tool.inputSchema as {type:'object';oneOf?:ReadinessInputVariant[];anyOf?:ReadinessInputVariant[]};
      const variants:ReadinessInputVariant[]|undefined=schema.oneOf??schema.anyOf;assert.ok(Array.isArray(variants));
      for(const operation of ['start','status','cancel']) {
        const variant:ReadinessInputVariant|undefined=variants.find(value=>value.properties?.operation?.const===operation);assert.ok(variant);
        assert.equal(variant.additionalProperties,false);
        assert.deepEqual([...variant.required].sort(),operation==='start'?['deviceIDs','operation','requestID']:['operation','requestID']);
        assert.equal(variant.properties.requestID.format,'uuid');
        if(operation==='start') {
          assert.ok(variant.properties.deviceIDs);
          const devices:NonNullable<ReadinessInputVariant['properties']['deviceIDs']>=variant.properties.deviceIDs;
          assert.equal(devices.minItems,2);assert.equal(devices.maxItems,2);
        }
      }
      const requestID=randomUUID(),deviceIDs=[randomUUID(),randomUUID()],before=await databaseFingerprint(root);
      for(const operation of ['start','status','cancel','start']) {
        const result=await client.callTool({name:'notebook_history_readiness',arguments:{operation,requestID,
          ...(operation==='start'?{deviceIDs}:{})}});
        assert.equal(result.isError,true);
        const content=result.structuredContent as any;
        assert.equal(content.status,'error');assert.equal(content.code,'native_owner_required');
        assert.equal(Object.hasOwn(content,'value'),false,'Core must not fabricate a paired report');
        assert.equal(Object.hasOwn(content,'ready'),false);
      }
      assert.equal(admissions,4,'Valid attach operations must reach the admitted existing IPC owner');
      const mixedCaseDeviceID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
      for(const arguments_ of [
        {operation:'start',requestID,deviceIDs:[deviceIDs[0]]},
        {operation:'start',requestID,deviceIDs:[...deviceIDs,randomUUID()]},
        {operation:'start',requestID,deviceIDs:[deviceIDs[0],deviceIDs[0]]},
        {operation:'start',requestID,deviceIDs:[mixedCaseDeviceID,mixedCaseDeviceID.toUpperCase()]},
        {operation:'start',requestID:'bad',deviceIDs},
        {operation:'status',requestID,deviceIDs}, {operation:'cancel',requestID,deviceIDs},
        {operation:'status',requestID,workspaceID:randomUUID()},
      ]) {
        const admissionsBefore:number=admissions;
        const result=await client.callTool({name:'notebook_history_readiness',arguments:arguments_});
        assert.equal(result.isError,true);
        assert.equal(admissions,admissionsBefore,'Invalid shape must fail before runtime admission and native IPC');
      }
      assert.deepEqual(await databaseFingerprint(root),before);
    } finally {await client.close();await server.close();}
  });
});
