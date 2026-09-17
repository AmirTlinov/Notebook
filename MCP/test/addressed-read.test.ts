import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { NotebookStore } from "./native-client.js";
import { writeFixture, fixtureSocket, stopFixture, pageID } from "./fixture.js";
import { revision } from "../src/domain.js";

test("native addressed read exposes the same committed versions and element without a whole page", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-addressed-ipc-"));
  try {
    await writeFixture(root);
    const store = new NotebookStore(fixtureSocket(root));
    const page = await store.readPage(pageID), target = {kind:"page",id:pageID};
    await store.command({command:"apply", action:{id:randomUUID(),summary:"Addressed element",references:[],
      expected:[{target,revision:revision(page.agentStamp)}],operations:[{kind:"insertElement",target,id:"late",
        values:{kind:"markdown",source:"Only this element",frame:{x:10,y:10,width:100,height:100}}}]}});
    const read = await store.command<any>({command:"read",queries:[
      {kind:"pageHeader",id:pageID}, {kind:"pageElement",id:pageID,elementID:"late"},
      {kind:"pageElement",id:pageID,elementID:"missing"},
    ]});
    assert.deepEqual(read.values[0],read.values[1].header);
    assert.equal(read.values[1].element.source,"Only this element");
    assert.equal(read.values[2],null);
    assert.equal(read.values[0].elements,undefined);
    assert.equal(read.values[0].drawingData,undefined);
    assert.equal(typeof read.cursor,"string");
    assert.deepEqual(read.values[1].element,(await store.readPage(pageID)).elements.find(x=>x.id==="late"));
    const hits = await store.command<any>({command:"search",query:"element",limit:1,filters:{kinds:["page"],target}});
    assert.equal(hits.results[0].elementID,"late");
    assert.equal(hits.coverage.complete,true);
    assert.equal(hits.coverage.next,undefined);
  } finally { await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});
