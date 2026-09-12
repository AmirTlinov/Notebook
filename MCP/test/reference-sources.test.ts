import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { BridgeError, runBridge } from "../src/bridge.js";
import { NotebookStore } from "../src/store.js";
import { revision } from "../src/domain.js";
import { appActor, pageID, rootBoardID, writeFixture, fixtureSocket, stopFixture } from "./fixture.js";

test("native reference/render address one page despite unrelated catalog growth",async()=>{
  const root=await mkdtemp(join(tmpdir(),"notebook-reference-"));
  try{
    await writeFixture(root);const socket=fixtureSocket(root),store=new NotebookStore(socket);
    const target={kind:"page",id:pageID};
    const before=await runBridge<{revision:string}>(socket,{command:"reference",target});
    const header=await store.readHeader();
    const owner={kind:"board",id:rootBoardID};
    await store.command({command:"apply",action:{id:randomUUID(),summary:"Независимая тетрадь",references:[],
      expected:[{target:owner,revision:await store.readBoardContentRevision(rootBoardID)},{target:{kind:"workspace",id:rootBoardID},revision:revision(header.stamp)}],
      operations:[{kind:"createNotebook",target:owner,id:randomUUID(),values:{title:"Независимая",center:{tileX:10,tileY:20,localX:0,localY:0},pageID:randomUUID()}}]}});
    const input={command:"render",target,expectedRevision:`0@${appActor}`};
    const request=await runBridge<{id:string;sourceRevision:string}>(socket,input);
    assert.equal(request.sourceRevision,before.revision);
    assert.deepEqual(await runBridge(socket,input),request);
    assert.deepEqual(await runBridge(socket,{command:"reference",target}),before);
    await assert.rejects(runBridge(socket,{...input,expectedRevision:`99@${appActor}`}),error=>error instanceof BridgeError && error.detail.code==="revision_conflict");
  }finally{await stopFixture(root);await rm(root,{recursive:true,force:true});}
});
