import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { actionSchema } from "../src/actions.js";
import { revision, type AgentElement, type SpatialElement } from "../src/domain.js";
import { NotebookStore } from "./native-client.js";
import { writeFixture, fixtureSocket, stopFixture, pageID, rootBoardID } from "./fixture.js";

test("native IPC exposes editable geometry to the agent and causally undoes edit, deletion and conversion", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-graphic-ipc-"));
  try {
    await writeFixture(root);
    const store = new NotebookStore(fixtureSocket(root)), target = { kind: "page", id: pageID };
    const sourceID = randomUUID();
    async function action(kind: string, id: string, values: unknown) {
      const page = await store.readPage(pageID), actionID = randomUUID();
      const action = actionSchema.parse({ summary: kind, references: [],
        expected: [{ target, revision: revision(page.agentStamp), inkRevision: revision(page.drawingStamp) }],
        operations: [{ kind, target, id, values }] });
      await assert.doesNotReject(store.command({ command: "apply", action: { ...action, id: actionID } }), kind);
      return actionID;
    }
    await action("appendInkStroke", sourceID, { points: Array.from({ length: 49 }, (_, i) => ({
      x: 150 + 60 * Math.cos(i / 48 * 2 * Math.PI), y: 150 + 60 * Math.sin(i / 48 * 2 * Math.PI),
    })) });
    const raw = (await store.readPage(pageID)).drawingData;
    const converted = await action("convertInkToElement", "circle", { kind: "graphic", source: "",
      frame: { x: 90, y: 90, width: 120, height: 120 }, graphic: { shape: "ellipse", label: "",
        style: { stroke: { red: 0, green: 0, blue: 0 }, strokeWidth: 2 }, representation: "geometry", visible: true, sourceInkIDs: [sourceID] } });
    const edit = await action("updateElement", "circle", { graphic: { label: "1:2" } });
    const read = (await store.readPage(pageID)) as { elements: Array<{ id: string; graphic: { label: string } }> };
    assert.equal(read.elements.find(x => x.id === "circle")?.graphic.label, "1:2");
    const deleted = await action("removeElement", "circle", {});
    assert.equal((await store.readPage(pageID)).elements.find(x => x.id === "circle")?.graphic?.visible, false);
    for (const [step, actionID] of [["deletion", deleted], ["edit", edit], ["conversion", converted]])
      await assert.doesNotReject(store.command({ command: "undo", actionID }), `undo ${step}`);
    const page = await store.readPage(pageID), graphic = page.elements.find(x => x.id === "circle")?.graphic;
    assert.equal(graphic?.representation, "ink"); assert.equal(graphic?.visible, true);
    assert.equal(graphic?.label, ""); assert.equal(page.drawingData, raw);
  } finally { await stopFixture(root); await rm(root, { recursive: true, force: true }); }
});

for (const board of [false,true]) test(`native IPC keeps bound connector intent and derived visibility on ${board ? "board" : "page"}`, async () => {
  const root = await mkdtemp(join(tmpdir(),"notebook-connector-ipc-"));
  try {
    await writeFixture(root);
    const store = new NotebookStore(fixtureSocket(root)), target = {kind:board ? "board" : "page",id:board ? rootBoardID : pageID};
    async function action(operations:unknown[]) {
      const current = board ? await store.readBoardContentRevision(rootBoardID) : revision((await store.readPage(pageID)).agentStamp);
      const parsed = actionSchema.parse({summary:"Editable connection",references:[{id:randomUUID(),target,revision:current,label:"Diagram owner"}],expected:[{target,revision:current}],operations});
      const id = randomUUID();
      await store.command({command:"apply",action:{...parsed,id}});
      return id;
    }
    const base = {shape:"ellipse",label:"+",style:{stroke:{red:0,green:0,blue:0},strokeWidth:2},representation:"geometry",visible:true,sourceInkIDs:[]};
    const op = (kind:string,id:string,values:unknown={}) => ({kind,target,id,values});
    const insert = (id:string,x:number,graphic:object=base) => op("insertElement",id,{kind:"graphic",source:"",frame:{x,y:100,width:100,height:100},graphic,
      ...(board ? {worldOrigin:{tileX:0,tileY:0,localX:0,localY:0}} : {})});
    const endpoint = (id:string) => ({point:{x:0,y:0},binding:{elementID:id,normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:true}});
    const read = async (id:string):Promise<AgentElement|SpatialElement|undefined> => board
      ? store.read({kind:"boardElement",id:rootBoardID,elementID:id}) : (await store.readPage(pageID)).elements.find(x=>x.id===id);
    const creation = await action([insert("a",60),insert("b",460)]);
    await action([insert("ab",180,{...base,shape:"connector",label:"1:2",connection:{start:endpoint("a"),end:endpoint("b"),bend:0,startArrowhead:"none",endArrowhead:"arrow",labelPosition:0.5}})]);
    const initial = await read("ab");
    assert.equal(initial?.graphicResolution?.state,"geometry");
    const move = await action([op("updateElement","a",{frame:{x:60,y:300,width:100,height:100}})]);
    const moved = await read("ab");
    assert.deepEqual(moved?.graphic,initial?.graphic);
    assert.notDeepEqual(moved?.graphicResolution,initial?.graphicResolution);
    const removal = await action([op("removeElement","a")]);
    assert.deepEqual((await read("ab"))?.graphicResolution,{state:"hidden"});
    assert.equal((await read("ab"))?.graphic?.connection?.start.binding?.elementID,"a");
    for (const actionID of [removal,move]) await store.command({command:"undo",actionID});
    assert.deepEqual((await read("ab"))?.graphicResolution,initial?.graphicResolution);
    await store.command({command:"undo",actionID:creation});
    assert.equal((await read("ab"))?.graphicResolution?.state,"geometry","Later link protects its nodes");
    const invalid = action([insert("never-written",120),op("updateElement","ab",{graphic:{connection:{end:endpoint("missing")}}})]);
    await assert.rejects(invalid,/привяз|binding|узел/i);
    assert.equal(await read("never-written"),board ? null : undefined,"An invalid binding rolls back the entire action");
  } finally { await stopFixture(root); await rm(root,{recursive:true,force:true}); }
});
