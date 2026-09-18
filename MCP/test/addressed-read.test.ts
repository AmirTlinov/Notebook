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
    const full=(await store.readPage(pageID)).elements.find(x=>x.id==="late");
    assert.ok(full);
    const {appearance,...authored}=full as typeof full & {appearance:unknown};
    assert.deepEqual(read.values[1].element,authored);
    assert.deepEqual(read.values[1].appearance,appearance);
    assert.deepEqual(appearance,{state:"intact",sourceIsCompleteAppearance:true});
    const hits = await store.command<any>({command:"search",query:"element",limit:1,filters:{kinds:["page"],target}});
    assert.equal(hits.results[0].elementID,"late");
    assert.equal(hits.coverage.complete,true);
    assert.equal(hits.coverage.next,undefined);
  } finally { await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});

test("native observations page once, then return only addressed changes", async () => {
  const root=await mkdtemp(join(tmpdir(),"notebook-observation-ipc-"));
  try {
    await writeFixture(root); const store=new NotebookStore(fixtureSocket(root)), target={kind:"page",id:pageID};
    const apply=async (operations:unknown[])=>store.command({command:"apply",action:{id:randomUUID(),summary:"Delta",references:[],
      expected:[{target,revision:revision((await store.readPage(pageID)).agentStamp)}],operations}});
    await apply(["delta-a","delta-b"].map(id=>({kind:"insertElement",target,id,values:{kind:"markdown",source:id,frame:{x:10,y:10,width:100,height:100}}})));
    const scope={target,ids:["delta-a","delta-b"],fields:["content"]};
    const observe=async(extra:Record<string,unknown>={})=>(await store.command<any>({command:"read",queries:[{kind:"observation",scope,limit:1,...extra}]})).values[0];
    const first=await observe(); assert.equal(first.checkpoint,undefined); assert.equal(first.coverage.complete,false);
    const last=await observe({next:first.coverage.next}); assert.equal(last.coverage.complete,true);
    await apply([{kind:"updateElement",target,id:"delta-b",values:{source:"Changed"}}]);
    const delta=await observe({since:last.checkpoint});
    assert.equal(delta.mode,"delta"); assert.deepEqual(delta.objects.map((x:any)=>x.id),["delta-b"]);
    assert.equal(delta.objects[0].value.content.source,"Changed");
    assert.equal((await observe({since:delta.checkpoint})).objects.length,0);
  } finally { await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});
