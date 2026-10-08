import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {NotebookStore} from './native-client.js';
import {rootBoardID,writeFixture,fixtureSocket,stopFixture} from './fixture.js';
import {readDataSchemas,snapshotSchema} from '../src/sdk-results.js';

test('generated script declarations type history evidence without exposing authored payloads or migration authority',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-history-types-'));
  try {
    const declarations=await readFile(new URL('../../Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts',import.meta.url));
    await writeFile(join(root,'notebook-sdk.d.ts'),declarations);
    await writeFile(join(root,'script.ts'),`async function inspectHistory() {
      const directory=await nb.read({kind:'actionHistoryPreflight',limit:2});
      const cursor:string=directory.data.cut.readCursor;
      if(directory.data.mode==='inventory') {
        for(const transaction of directory.data.transactions) {
          const sequence:string|undefined=transaction.localJournal?.sequence;
          const accepted=await nb.read({kind:'actionHistoryPreflight',id:transaction.transactionID,
            revision:transaction.manifestHash,referenceID:'00000000-0000-4000-8000-000000000001'});
          if(accepted.data.mode==='transaction') for(const receipt of accepted.data.receipts) {
            const bytes:number=receipt.fragmentBytes;
            if(receipt.closure==='unprovenClosure') {
              const reason:'originalRootAbsent'|'rootRemoved'|'externalizedMembership'|'unreferencedFragments'|
                'originalAnchorUnavailable'|'originalAnchorMismatch'=receipt.reason;
              await emit({reason,bytes,sequence,cursor});
            } else if(receipt.closure==='completeOriginalBody') {
              const version:string=receipt.originalAnchor.originalVersion;
              const original:string=receipt.originalAnchor.originalRootHash;
              const model:string=receipt.originalAnchor.modelRootHash;
              const result:string=receipt.originalAnchor.resultRootHash;
              await emit({version,original,model,result});
              // @ts-expect-error: a source-local body digest does not identify its author
              const actor=receipt.originalAnchor.deviceID;
            }
            // @ts-expect-error: this report exposes closure metadata only
            const payload=receipt.rawPayload;
          }
          // @ts-expect-error: an accepted occurrence is not a migration seal
          const seal=transaction.migrationAuthority;
        }
      }
    }`);
    await writeFile(join(root,'tsconfig.json'),JSON.stringify({compilerOptions:{strict:true,noEmit:true,
      noEmitOnError:true,skipLibCheck:false,lib:['ES2023'],types:[],target:'ES2023',module:'esnext'},
      files:['notebook-sdk.d.ts','script.ts']}));
    const compiler=fileURLToPath(new URL('../node_modules/.bin/tsc',import.meta.url));
    await promisify(execFile)(compiler,['--project',join(root,'tsconfig.json')],{maxBuffer:1024*1024});
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('history body proof summary accepts only bounded source-root hashes and preserves explicit missing evidence',()=>{
  const id=randomUUID(),hash='a'.repeat(64);
  const transaction={mode:'transaction',cut:{workspaceID:id,snapshotID:randomUUID(),readCursor:'71'},
    transactionID:randomUUID(),manifestHash:hash,manifestFormat:26,
    receipts:[{id,fragmentCount:3,fragmentBytes:1234,closure:'completeOriginalBody',
      originalAnchor:{originalVersion:hash,originalRootHash:'b'.repeat(64),
        modelRootHash:'c'.repeat(64),resultRootHash:'d'.repeat(64)}}]};
  const schema=readDataSchemas.actionHistoryPreflight;
  assert.equal(schema.safeParse(transaction).success,true);
  const receipt=transaction.receipts[0];
  assert.ok(receipt);
  for(const extra of [{rawPayload:'authored bytes'},{body:{unknown:'authored JSON'}},{birthTransactionID:transaction.transactionID}]) {
    assert.equal(schema.safeParse({...transaction,receipts:[{...receipt,...extra}]}).success,false);
  }
  assert.equal(schema.safeParse({...transaction,receipts:[{...receipt,
    originalAnchor:{...receipt.originalAnchor,deviceID:randomUUID()}}]}).success,false);
  assert.equal(schema.safeParse({...transaction,receipts:[{...receipt,
    originalAnchor:{...receipt.originalAnchor,originalVersion:'BAD'}}]}).success,false);
  for(const reason of ['externalizedMembership','originalAnchorUnavailable','originalAnchorMismatch']) {
    assert.equal(schema.safeParse({...transaction,receipts:[{id,fragmentCount:3,fragmentBytes:1234,
      closure:'unprovenClosure',reason}]}).success,true);
  }
});

test('native history preflight retains exact cuts and reports missing original roots through the SDK contract',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-history-preflight-ipc-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root));
    const schema=snapshotSchema(readDataSchemas.actionHistoryPreflight);
    const read=async(query:unknown)=>{
      const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]});
      const parsed=schema.safeParse(snapshot);
      assert.equal(parsed.success,true,JSON.stringify(parsed));
      assert.deepEqual(snapshot.basis.owners,[]);
      assert.equal(snapshot.data.cut.workspaceID,snapshot.basis.workspaceID);
      assert.equal(snapshot.data.cut.readCursor,snapshot.cursor);
      return snapshot;
    };
    const first=await read({kind:'actionHistoryPreflight',limit:1});
    assert.equal(first.data.mode,'inventory');
    const transaction=first.data.transactions[0];
    assert.ok(transaction,'The native seed must produce an accepted journal occurrence');
    assert.equal(typeof transaction.localJournal.sequence,'string');
    const transactions=[transaction.transactionID],snapshots=[first.data.cut.snapshotID];
    let current=first;
    while(current.coverage.next) {
      current=await read({kind:'actionHistoryPreflight',next:current.coverage.next,limit:2});
      assert.equal(current.cursor,first.cursor);
      snapshots.push(current.data.cut.snapshotID);
      transactions.push(...current.data.transactions.map((value:any)=>value.transactionID));
    }
    assert.equal(current.coverage.complete,true);
    assert.equal(new Set(transactions).size,transactions.length);
    assert.deepEqual(transactions,[...transactions].sort());
    assert.equal(new Set(snapshots).size,snapshots.length);
    const receiptID=randomUUID();
    const point=await read({kind:'actionHistoryPreflight',id:transaction.transactionID,
      revision:transaction.manifestHash,referenceID:receiptID});
    assert.equal(point.data.mode,'transaction');
    assert.equal(point.data.manifestHash,transaction.manifestHash);
    assert.equal(point.cursor,first.cursor);
    assert.equal(point.coverage.complete,false);
    assert.equal(point.coverage.next,undefined);
    assert.deepEqual(point.data.receipts,[{id:receiptID.toUpperCase(),closure:'unprovenClosure',
      reason:'originalRootAbsent',fragmentCount:0,fragmentBytes:0}]);
    assert.equal(JSON.stringify(point).includes('rawPayload'),false);

    const [board]=await store.command<any[]>({command:'read',readSnapshots:true,
      queries:[{kind:'boardContentRevision',id:rootBoardID}]});
    const target={kind:'board',id:rootBoardID},actionID=randomUUID();
    const action={id:actionID,summary:'Source-bound history receipt',references:[],
      additionalOwners:[target],expected:board.basis.owners,operations:[{kind:'insertElement',target,
        id:'history-source-label',values:{kind:'nativeText',source:'History source',
          frame:{x:10,y:20,width:200,height:80},worldOrigin:{tileX:0,tileY:0,localX:0,localY:0},
          textStyle:{fontSize:42,weight:0.6,red:0.2,green:0.4,blue:0.8,alpha:0.75}}}]};
    const admission=await store.command<any>({command:'admitAction',action});
    const prepared=await store.command<any>({command:'prepareAction',actionID,fingerprint:admission.fingerprint});
    const result=await store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    let directory=await read({kind:'actionHistoryPreflight',limit:64}),proved=0;
    assert.notEqual(directory.cursor,first.cursor);
    const committedCursor=directory.cursor;
    do {
      for(const occurrence of directory.data.transactions) {
        const accepted=await read({kind:'actionHistoryPreflight',id:occurrence.transactionID,
          revision:occurrence.manifestHash,referenceID:actionID});
        assert.equal(accepted.cursor,committedCursor);
        const receipt=accepted.data.receipts[0];
        if(receipt.closure!=='completeSelfContained') continue;
        assert.equal(accepted.coverage.complete,true);
        assert.equal(receipt.id.toLowerCase(),actionID.toLowerCase());
        assert.equal(result.actionID.toLowerCase(),actionID.toLowerCase());
        assert.match(result.actionVersion,/^[a-f0-9]{64}$/);
        assert.equal(receipt.fragmentCount,1);
        assert.deepEqual(Object.keys(receipt).sort(),['closure','fragmentBytes','fragmentCount','id']);
        assert.equal(JSON.stringify(accepted).includes('History source'),false);
        assert.equal(JSON.stringify(accepted).includes('history-source-label'),false);
        proved++;
      }
      if(!directory.coverage.next) break;
      directory=await read({kind:'actionHistoryPreflight',next:directory.coverage.next,limit:64});
      assert.equal(directory.cursor,committedCursor);
    } while(true);
    assert.equal(proved>0,true,'A real committed receipt must expose its complete self-contained body proof');
  } finally {
    await stopFixture(root);
    await rm(root,{recursive:true,force:true});
  }
});
