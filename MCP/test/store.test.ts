import assert from "node:assert/strict";
import { chmod, lstat, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { BridgeError, runBridge } from "../src/bridge.js";
import { NotebookStore, visibleBounds, workspaceProjection, type ScenePaintPage } from "../src/store.js";
import { TILE_SIZE } from "../src/spatial.js";
import { revision } from "../src/domain.js";
import { appActor, itemID, pageID, rootBoardID, writeFixture, fixtureControl, fixtureSocket, stopFixture } from "./fixture.js";

async function withStore(body:(store:NotebookStore,root:string)=>Promise<void>):Promise<void> {
  const root=await mkdtemp(join(tmpdir(),"notebook-mcp-"));
  try {await writeFixture(root);await body(new NotebookStore(fixtureSocket(root)),root);}
  finally{await stopFixture(root);await rm(root,{recursive:true,force:true});}
}

test("reads the selected physical page through the real IPC owner with no canonical JSON files",async()=>{
  await withStore(async(store,root)=>{
    const canonical = await fixtureControl<{workspace:{format:number;isProjection:boolean;pageOrders:Record<string,unknown>;pageOrderNodes:Record<string,unknown>}}>(root,"readFixture");
    assert.equal(canonical.workspace.format,5);
    assert.equal(canonical.workspace.isProjection,false);
    assert.equal(Object.keys(canonical.workspace.pageOrders).length,1);
    assert.ok(Object.keys(canonical.workspace.pageOrderNodes).length > 0,"Core authors the immutable page-order witnesses");
    const page=await store.readCurrentPage();
    assert.equal(page.id.toLowerCase(),pageID);assert.equal(revision(page.agentStamp),`0@${appActor}`);
    for(const path of ["workspace.json","board.json","spatial-ink.json","last-context.json",`pages/${pageID}.json`]) {
      await assert.rejects(readFile(join(root,path)),{code:"ENOENT"});
    }
  });
});

test("the production transport cannot accept a different root or filesystem path",async()=>{
  await withStore(async(store,root)=>{
    await assert.rejects(runBridge(store.socketPath,{command:"read",queries:[],root}),error=>error instanceof BridgeError && error.detail.code==="invalid_command");
    await assert.rejects(runBridge(store.socketPath,{command:"snapshot"}),error=>error instanceof BridgeError && error.detail.code==="invalid_command");
    await assert.rejects(runBridge(store.socketPath,{command:"artifact",artifact:{kind:"pageRegion",id:pageID,regionID:"../../workspace.json",expectedSHA256:"0".repeat(64)}}));
  });
});

test("missing IPC reports endpoint availability, not process state, and never creates a second writer",async()=>{
  const root=await mkdtemp(join(tmpdir(),"notebook-no-owner-"));
  try {
    await assert.rejects(new NotebookStore(join(root,"absent.sock")).readHeader(),error=>{
      assert.ok(error instanceof BridgeError);
      assert.equal(error.detail.code,"ipc_unavailable");
      assert.match(error.message,/совместимой сборки Mac-помощника/);
      assert.doesNotMatch(error.message,/helper не запущен/);
      return true;
    });
    await assert.rejects(lstat(join(root,"notebook.sqlite")),{code:"ENOENT"});
  }finally{await rm(root,{recursive:true,force:true});}
});

test("socket permissions are private and an insecure endpoint is rejected",async()=>{
  await withStore(async(store)=>{
    assert.equal((await lstat(store.socketPath)).mode & 0o777,0o600);
    await chmod(store.socketPath,0o666);
    await assert.rejects(store.readHeader(),error=>error instanceof BridgeError && error.detail.code==="ipc_unauthorized");
    await chmod(store.socketPath,0o600);
  });
});

test("reads one bounded board window, selected metadata, ink and presence",async()=>{
  await withStore(async(store)=>{
    const presence=await store.readPresence();const window=await store.readSceneWindow(rootBoardID,visibleBounds(presence),1);
    assert.equal(window.items[0]?.id.toLowerCase(),itemID);assert.equal(window.truncated,false);
    const addressed = await store.readWorkspaceProjection([itemID,itemID.toUpperCase()]);
    const scene = workspaceProjection(window);
    const keys = ["items","rootBoardID","selectedItemID","selectedPageID","stamp"];
    for (const projection of [addressed,scene]) {
      assert.deepEqual(Object.keys(projection).sort(),keys,"A metadata projection never impersonates an archive format or causal witness");
      assert.equal(projection.rootBoardID.toLowerCase(),rootBoardID);
      assert.deepEqual(projection.items.map(item=>item.id.toLowerCase()),[itemID]);
      assert.deepEqual(projection.stamp,window.header.stamp);
      assert.equal(projection.selectedPageID?.toLowerCase(),pageID);
    }
    const ink=await store.readSpatialInk([{kind:"board",ownerID:rootBoardID}]);assert.equal(ink.actions.length,0);
    assert.equal(presence.mode,"page");
  });
});

test("read batches refuse more than four physical pages and unbounded scene limits",async()=>{
  await withStore(async(store)=>{
    await assert.rejects(store.command({command:"read",queries:Array.from({length:5},()=>({kind:"page",id:randomUUID()}))}),error=>error instanceof BridgeError && error.detail.code==="resource_limit");
    const presence=await store.readPresence();
    await assert.rejects(store.readSceneWindow(rootBoardID,visibleBounds(presence),100_000));
    await assert.rejects(store.command({command:"read",queries:Array.from({length:5},()=>({kind:"documentBlock",id:randomUUID(),elementID:"body"}))}),
      error=>error instanceof BridgeError && error.detail.code==="resource_limit");
  });
});

test("one document block uses an explicit bounded query instead of whole source and state reads",async()=>{
  await withStore(async(store,root)=>{
    const header=await store.readHeader(),board=await store.readItemBoard(itemID),id=randomUUID(),blockID=randomUUID().toUpperCase();
    const target={kind:"board",id:rootBoardID};
    await store.command({command:"apply",action:{id:randomUUID(),summary:"One selected program",references:[],
      expected:[{target,revision:revision(board.stamp)},{target:{kind:"workspace",id:rootBoardID},revision:revision(header.stamp)}],
      operations:[{kind:"createDocument",target,id,values:{center:{tileX:0,tileY:0,localX:20,localY:20},paperSize:"a4",
        blocks:[{id:blockID,kind:"interactive",html:"<button>+</button>",initialState:{count:3}}]}}]}});
    await fixtureControl(root,"readQueries");
    const read=await store.readDocumentBlock(id,blockID.toLowerCase());
    assert.ok(read);
    assert.equal(read.block.id,blockID);
    assert.equal(Object.hasOwn(read,"state"),false);
    assert.deepEqual(read.block.initialState,{count:3});
    assert.equal(Object.hasOwn(read,"format"),false);
    assert.deepEqual(await fixtureControl(root,"readQueries"),["documentBlock"]);
    assert.equal(await store.readDocumentBlock(id,"absent"),null);
  });
});

test("real IPC reads outside projection edges without rounding or changing physical owners",async()=>{
  await withStore(async(store,root)=>{
    const initial = await store.readPresence();
    for (const sign of [-1, 1]) {
      const anchor = {tileX:sign * Number.MAX_SAFE_INTEGER,tileY:sign * Number.MAX_SAFE_INTEGER,
        localX:sign < 0 ? 0 : TILE_SIZE - 1,localY:sign < 0 ? 0 : TILE_SIZE - 1};
      await fixtureControl(root,"moveItem",anchor);
      await fixtureControl(root,"presence",{...initial,camera:{...initial.camera,center:anchor}});
      const bounds = visibleBounds(await store.readPresence());
      const window = await store.readSceneWindow(rootBoardID,bounds,1);
      assert.equal(window.items[0]?.id.toLowerCase(),itemID);
      const page = await store.read<ScenePaintPage>({kind:"scenePaintOrder",id:rootBoardID,bounds,limit:1});
      assert.equal(page.entries[0]?.id.toLowerCase(),itemID);
      const outside = sign < 0 ? page.entries[0]!.bounds.origin : page.entries[0]!.bounds.maximum;
      assert.equal(BigInt(outside.tileX),BigInt(sign) * (BigInt(Number.MAX_SAFE_INTEGER) + 1n));
      assert.equal(BigInt(outside.tileY),BigInt(sign) * (BigInt(Number.MAX_SAFE_INTEGER) + 1n));
      const physical = (await store.readItemBoard(itemID)).freeItems[0]!.center;
      assert.deepEqual(physical,anchor);
      await assert.rejects(store.readSceneWindow(rootBoardID,{...bounds,region:{...bounds.region,width:10_000_001}},1));
    }
  });
});

test("a completed commit invalidates a staged read cursor instead of mixing generations",async()=>{
  await withStore(async(store,root)=>{
    const first=await store.command<{cursor:string}>({command:"read",queries:[]});
    const presence=await store.readPresence();await fixtureControl(root,"presence",{...presence,camera:{...presence.camera,scale:0.9}});
    await assert.rejects(store.command({command:"read",expectedCursor:first.cursor,queries:[{kind:"presence"}]}),error=>error instanceof BridgeError && error.detail.code==="read_conflict");
  });
});

test("one read operation replays a conflicted addressed cut and returns a coherent result",async()=>{
  await withStore(async(store,root)=>{
    let attempts=0;
    const result=await store.withReadSnapshot(async()=>{
      attempts++;const before=await store.readPresence();
      if(attempts===1)await fixtureControl(root,"presence",{...before,camera:{...before.camera,scale:1.1}});
      const header=await store.readHeader();
      return {before,header};
    });
    assert.equal(attempts,2);assert.equal(result.before.camera.scale,1.1);
  });
});

test("a swallowed read conflict still cannot return a mixed observation",async()=>{
  await withStore(async(store,root)=>{
    let attempts=0;
    await store.withReadSnapshot(async()=>{
      attempts++;const before=await store.readPresence();
      if(attempts===1)await fixtureControl(root,"presence",{...before,camera:{...before.camera,scale:1.2}});
      await store.readHeader().catch(()=>null);
    });
    assert.equal(attempts,2);
  });
});

test("requires a typed surface receipt rather than trusting an artifact JSON",async()=>{
  await withStore(async(store,root)=>{
    const path=join(root,"previews/current-view.revision"),receipt=JSON.parse(await readFile(path,"utf8"));
    delete receipt.surface;await writeFile(path,JSON.stringify(receipt));
    await assert.rejects(store.readCurrentViewReceipt(),error=>error instanceof BridgeError && error.detail.code==="invalid_artifact");
  });
});

for(const [name,mutate] of [
  ["zero physical size",(p:any)=>{p.size.width=0;}],
  ["unbounded physical size",(p:any)=>{p.size.width=1e100;}],
  ["inexact JavaScript revision",(p:any)=>{p.agentStamp.counter=Number.MAX_SAFE_INTEGER+1;}],
] as const) test(`native owner rejects ${name} before publication`,async()=>{
  await withStore(async(store,root)=>{
    const before=await store.readPage(pageID),invalid=structuredClone(before);mutate(invalid);
    await assert.rejects(fixtureControl(root,"page",invalid));assert.deepEqual(await store.readPage(pageID),before);
  });
});

test("scene identity belongs to Core metadata and changes after an addressed scene commit",async()=>{
  await withStore(async(store)=>{
    const before=(await store.readHeader()).boardRevision;
    const board=await store.readItemBoard(itemID);
    const target={kind:"cover",id:itemID,boardID:rootBoardID};
    await store.command({command:"apply",action:{id:randomUUID(),summary:"A new meaning on the cover",additionalOwners:[target],
      references:[],expected:[{target,revision:revision(board.stamp)}],operations:[{kind:"insertElement",target,id:"identity-proof",
        values:{kind:"nativeText",source:"Changed scene",frame:{x:10,y:10,width:150,height:30}}}]}});
    assert.notEqual((await store.readHeader()).boardRevision,before);
  });
});

test("a rich cover is read in bounded physical paint pages and stale cursors fail closed",async()=>{
  await withStore(async(store)=>{
    const board=await store.readItemBoard(itemID);
    const target={kind:"cover",id:itemID,boardID:rootBoardID};
    const operations=Array.from({length:40},(_,index)=>({kind:"insertElement",target,id:`cover-${index}`,
      values:{kind:"nativeText",source:`Meaning ${index}`,frame:{x:20,y:20+index*24,width:300,height:20}}}));
    await store.command({command:"apply",action:{id:randomUUID(),summary:"Forty independent cover meanings",additionalOwners:[target],
      references:[],expected:[{target,revision:revision(board.stamp)}],operations}});
    assert.deepEqual((await store.readItemBoard(itemID)).elements,[],"A placement read must not load a rich cover");
    const size={width:834,height:1194};
    const first=await store.readCoverElements(itemID,size,undefined,16);
    assert.equal(first.elements.length,16);assert.equal(first.coverage.truncated,true);assert.ok(first.coverage.nextCursor);
    const second=await store.readCoverElements(itemID,size,first.coverage.nextCursor!,16);
    const last=await store.readCoverElements(itemID,size,second.coverage.nextCursor!,16);
    assert.equal(last.elements.length,8);assert.equal(last.coverage.nextCursor,null);
    assert.equal(new Set([...first.elements,...second.elements,...last.elements].map(element=>element.id)).size,40);
    const current=await store.readItemBoard(itemID);
    await store.command({command:"apply",action:{id:randomUUID(),summary:"One later correction",additionalOwners:[target],
      references:[],expected:[{target,revision:revision(current.stamp)}],operations:[{kind:"updateElement",target,id:"cover-0",values:{source:"Later"}}]}});
    await assert.rejects(store.readCoverElements(itemID,size,first.coverage.nextCursor!,16),
      error=>error instanceof BridgeError && error.detail.code==="read_conflict");
  });
});

test("notebook header, directory and page windows share exact UUID/root ownership",async()=>{
  await withStore(async(store,root)=>{
    const added=await fixtureControl<string[]>(root,"appendPages",8);
    const item=await store.readItem(itemID);
    assert.equal(item?.pageCount,9);
    assert.equal(item?.firstPageID?.toLowerCase(),pageID);
    assert.equal(Object.hasOwn(item!,"pageIDs"),false,"The wire never presents a partial array as canonical membership");
    const first=await store.readNotebookDirectory(itemID,0,4);
    assert.deepEqual(first.pages.map(page=>page.position.pageID.toLowerCase()),[pageID,...added.slice(0,3).map(id=>id.toLowerCase())]);
    assert.equal(first.nextIndex,4);
    assert.equal(first.header.selectedPageIndex,8);
    assert.match(first.header.readCursor,/^\d+$/);
    const second=await store.readNotebookDirectory(itemID,4,4,first.header.visibleRoot);
    const last=await store.readNotebookDirectory(itemID,second.nextIndex!,4,first.header.visibleRoot);
    assert.equal(last.pages.length,1);assert.equal(last.nextIndex,undefined);
    const window=await store.readNotebookPages(itemID,[{kind:"selection"},{kind:"index",index:0}]);
    assert.deepEqual(window.pages.map(page=>page.position.index),[8,0]);
    assert.equal(window.pages[0]?.document.id,added[7]);
    assert.equal(window.pages[0]?.position.readCursor,window.header.readCursor);
    assert.equal((await store.readNotebookPage(itemID)).id,added[7]);
    assert.equal((await store.readNotebookPage(itemID,5)).id,added[3]);
    assert.equal((await store.readNotebookPosition(added[3]!,itemID))?.index,4);
    assert.equal(await store.readNotebookPosition(randomUUID()),null);
    await assert.rejects(store.readNotebookPages(itemID,[{kind:"index",index:0},{kind:"page",id:pageID}]));
    await assert.rejects(store.command({command:"read",queries:[
      {kind:"notebookPages",id:itemID,pages:[{kind:"index",index:0},{kind:"index",index:1},{kind:"index",index:2}]},
      {kind:"notebookPages",id:itemID,pages:[{kind:"index",index:3},{kind:"index",index:4}]},
    ]}),error=>error instanceof BridgeError&&error.detail.code==="resource_limit");
    await fixtureControl(root,"appendPages",1);
    await assert.rejects(store.readNotebookDirectory(itemID,4,4,first.header.visibleRoot),
      error=>error instanceof BridgeError&&error.detail.code==="read_conflict");
    for(const kind of ["workspaceItems","workspaceItem","pageAtIndex","pageCount"]){
      await assert.rejects(store.read({kind,id:itemID}),error=>error instanceof BridgeError&&error.detail.code==="invalid_command");
    }
  });
});
