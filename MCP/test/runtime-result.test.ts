import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {readDataSchemas,snapshotSchema} from '../src/sdk-results.js';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture} from './fixture.js';

test('runtime snapshots distinguish an absent publication from an explicit connection status',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-runtime-result-'));
  try {
    await writeFixture(root);
    const store=new NotebookStore(fixtureSocket(root));
    const read=async()=>{
      const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'runtime'}]});
      return snapshot;
    };
    const absent=await read();
    assert.equal(absent.data,null,'a fresh owner has no runtime publication');
    assert.deepEqual(snapshotSchema(readDataSchemas.runtime).parse(absent),absent);
    assert.deepEqual(absent.basis.owners,[],'runtime publication grants no content write basis');

    // This is the isolated fixture's derivative, not live connection evidence.
    // Exercise native decoding of the existing optional publication verbatim.
    const publication={status:'disconnected',updatedAt:1234.5};
    await writeFile(join(root,'previews/runtime.json'),JSON.stringify(publication));
    const present=await read();
    assert.deepEqual(present.data,publication);
    assert.deepEqual(snapshotSchema(readDataSchemas.runtime).parse(present),present);
    assert.equal(present.cursor,absent.cursor,'a derivative does not mutate content');
    assert.equal(readDataSchemas.runtime.safeParse({status:'disconnected'}).success,false);
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});
