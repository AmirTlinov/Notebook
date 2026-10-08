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
import {writeFixture,fixtureSocket,stopFixture} from './fixture.js';
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
              const reason:'originalRootAbsent'|'rootRemoved'|'externalizedMembership'|'unreferencedFragments'=receipt.reason;
              await emit({reason,bytes,sequence,cursor});
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
  } finally {
    await stopFixture(root);
    await rm(root,{recursive:true,force:true});
  }
});
