import { NotebookStore } from "../src/store.js";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { BridgeError } from "../src/bridge.js";
import { deflateSync } from "node:zlib";

import type {
  BoardHierarchy,
  CurrentViewReceipt,
  PageDocument,
  SessionPresence,
  SpatialInkJournal,
  WorkspaceIndex,
} from "../src/domain.js";
import type { PageVisionReceipt } from "../src/page-vision.js";

export const itemID = "7e7a0000-0000-4000-8000-000000000001";
export const pageID = "7e7a0000-0000-4000-8000-000000000002";
export const appActor = "7e7a0000-0000-4000-8000-000000000003";
export const rootBoardID = "7e7a0000-0000-4000-8000-000000000003";

const previewPNG = grayscalePNG(1_668, 2_388, 255);
const currentViewPNG = grayscalePNG(700, 900, 96);
const regionPNG = grayscalePNG(52, 52, 0);

export async function writeFixture(root: string): Promise<void> {
  const workspace: WorkspaceIndex = {
    format: 4,
    collaboration:{fields:{}},
    rootBoardID,
    items: [
      {
        id: itemID,
        kind: "notebook",
        title: "Notebook 1",
        pageIDs: [pageID],
      },
    ],
    selectedItemID: itemID,
    selectedPageID: pageID,
    stamp: { counter: 0, actor: appActor },
  };
  const page: PageDocument = {
    format: 1,
    id: pageID,
    size: { width: 834, height: 1194 },
    drawingData: "",
    drawingStamp: { counter: 0, actor: appActor },
    elements: [],
    agentStamp: { counter: 0, actor: appActor },
  };
  const board: BoardHierarchy = {
    format: 1,
    rootBoardID,
    boards: [{
      id: rootBoardID,
      board: {
        format: 2,
        freeItems: [
          {
            itemID,
            center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
            zIndex: 0,
            stamp: { counter: 0, actor: appActor },
          },
        ],
        stacks: [],
        elements: [],
        stamp: { counter: 0, actor: appActor },
      },
    }],
    stamp: { counter: 0, actor: appActor },
  };
  const spatialInk: SpatialInkJournal = {
    format: 1,
    actions: [],
    stamp: { counter: 0, actor: appActor },
  };
  const presence: SessionPresence = {
    format: 5,
    boardID: rootBoardID,
    mode: "page",
    camera: {
      center: { tileX: 0, tileY: 0, localX: 0, localY: 0 },
      scale: 0.8,
    },
    viewport: { x: 834, y: 1_194 },
    focusedItemID: itemID,
    selectedItemID:itemID,notebookPageID:pageID,
    openProgress: 1,
    documentPageIndex: 0,
  };
  const currentViewReceipt: CurrentViewReceipt = {
    format: 6,
    workspaceStamp: workspace.stamp,
    boardRevision: "",
    spatialInkStamp: spatialInk.stamp,
    presence,
    renderViewport: { x: 700, y: 900 },
    pngSHA256: createHash("sha256").update(currentViewPNG).digest("hex"),
    surface: {
      kind: "page",
      itemID,
      revision: {
        pageID,
        drawingStamp: page.drawingStamp,
        agentStamp: page.agentStamp,
      },
      snapshotPNG_SHA256: createHash("sha256").update(previewPNG).digest("hex"),
    },
  };
  const previewSHA256 = createHash("sha256").update(previewPNG).digest("hex");
  const regionSHA256 = createHash("sha256").update(regionPNG).digest("hex");
  const gridSpacing = 132 / 2.54 / 2;
  const visionReceipt: PageVisionReceipt = {
    format: 2,
    pageID,
    drawingStamp: page.drawingStamp,
    pageSize: page.size,
    renderScale: 2,
    gridSpacing,
    gridColumns: Math.ceil(page.size.width / gridSpacing),
    gridRows: Math.ceil(page.size.height / gridSpacing),
    pixelSize: { width: 1_668, height: 2_388 },
    visibleInkBounds: { x: 0, y: 0, width: 1, height: 1 },
    occupiedCells: [{ column: 0, row: 0 }],
    regions: [
      {
        id: "r00-00-01-01",
        contentCells: { column: 0, row: 0, width: 1, height: 1 },
        cropCells: { column: 0, row: 0, width: 1, height: 1 },
        contentPoints: { x: 0, y: 0, width: gridSpacing, height: gridSpacing },
        cropPoints: { x: 0, y: 0, width: gridSpacing, height: gridSpacing },
        cropPixels: { x: 0, y: 0, width: 52, height: 52 },
        inkPixelCount: 1,
        faithfulPNG_SHA256: regionSHA256,
        inkPNG_SHA256: regionSHA256,
      },
    ],
    previewPNG_SHA256: previewSHA256,
    inkPNG_SHA256: previewSHA256,
  };
  await startFixture(root);
  await fixtureControl(root,"seed",{workspace,page,board,spatialInk,presence});
  const boardRevision = (await new NotebookStore(fixtureSocket(root)).readHeader()).boardRevision;
  if (!boardRevision) throw new Error("Seeded Core scene has no completed identity");
  currentViewReceipt.boardRevision = boardRevision;
  await mkdir(join(root, "previews/targets"), { recursive: true });
  await mkdir(join(root, "previews", `${pageID}.regions`), { recursive: true });
  // A minimal valid PNG is sufficient for MCP content-path verification.
  await writeFile(join(root, "previews", `${pageID}.png`), previewPNG);
  await writeFile(join(root, "previews", `${pageID}.ink.png`), previewPNG);
  await writeFile(
    join(root, "previews", `${pageID}.vision.json`),
    JSON.stringify(visionReceipt),
  );
  for (const mode of ["faithful", "ink"]) {
    await writeFile(
      join(root, "previews", `${pageID}.regions`, `r00-00-01-01.${mode}.png`),
      regionPNG,
    );
  }
  await writeFile(join(root, "previews", "current-view.png"), currentViewPNG);
  await writeFile(
    join(root, "previews", "current-view.revision"),
    JSON.stringify(currentViewReceipt),
  );
}

function grayscalePNG(width: number, height: number, value: number): Buffer {
  const bytesPerRow = width + 1;
  const pixels = Buffer.alloc(bytesPerRow * height, value);
  for (let row = 0; row < height; row += 1) {
    pixels[row * bytesPerRow] = 0;
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 0;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(pixels)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function pngChunk(type: string, data: Buffer): Buffer {
  const name = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([length, name, data, checksum]);
}

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

interface FixtureHost {
  process:ChildProcessWithoutNullStreams; socketPath:string; directory:string;
  requests:Map<string,{resolve:(value:any)=>void;reject:(error:Error)=>void;timer:ReturnType<typeof setTimeout>}>;
}
const hosts = new Map<string,FixtureHost>();
export function fixtureSocket(root:string):string {
  const host=hosts.get(root); if(!host) throw new Error("Fixture host is not running"); return host.socketPath;
}
async function startFixture(root:string):Promise<void> {
  if(hosts.has(root)) throw new Error("Fixture already running");
  const directory=await mkdtemp("/tmp/notebook-ipc-test-");
  const socketPath=join(directory,"bridge.sock");
  const binary=process.env.NOTEBOOK_IPC_TEST_HOST;
  if(!binary) throw new Error("Run MCP/test/run.sh to build the isolated IPC test host");
  const child=spawn(binary,[root,socketPath],{stdio:["pipe","pipe","pipe"]});
  const host:FixtureHost={process:child,socketPath,directory,requests:new Map()};
  hosts.set(root,host);
  let diagnostics="";
  child.stderr.on("data",(data:Buffer)=>{diagnostics=(diagnostics+data.toString()).slice(-16000);});
  const ready=new Promise<void>((resolve,reject)=>{
    const timer=setTimeout(()=>{reject(new Error("Fixture IPC startup timed out: "+diagnostics));child.kill();},10000);
    createInterface({input:child.stdout}).on("line",line=>{
      try {
        const message=JSON.parse(line);
        if(message.ready){clearTimeout(timer);resolve();return;}
        const pending=host.requests.get(message.id);
        if(pending){host.requests.delete(message.id);clearTimeout(pending.timer);
          if(message.error) pending.reject(new BridgeError(message.error)); else pending.resolve(message.result);}
      } catch(error){clearTimeout(timer);reject(error);}
    });
    child.once("error",error=>{clearTimeout(timer);reject(error);});
    child.once("exit",code=>{clearTimeout(timer);reject(new Error(`Fixture host exited ${code}: ${diagnostics}`));
      for(const request of host.requests.values()){clearTimeout(request.timer);request.reject(new Error("Fixture host exited: "+diagnostics));}host.requests.clear();});
  });
  await ready;
}
export function fixtureControl<T=any>(root:string,operation:string,value?:unknown):Promise<T> {
  const host=hosts.get(root); if(!host) return Promise.reject(new Error("Fixture host is not running"));
  const id=randomUUID();
  return new Promise<T>((resolve,reject)=>{
    const timer=setTimeout(()=>{host.requests.delete(id);reject(new Error("Fixture control timed out: "+operation));},10000);
    host.requests.set(id,{resolve,reject,timer});
    host.process.stdin.write(JSON.stringify({id,operation,value})+"\n");
  });
}
export async function stopFixture(root:string):Promise<void> {
  const host=hosts.get(root);if(!host)return;hosts.delete(root);
  const exited=new Promise<void>(resolve=>host.process.once("exit",()=>resolve()));
  host.process.stdin.end();
  const timer=setTimeout(()=>host.process.kill(),2000);
  await exited;clearTimeout(timer);await rm(host.directory,{recursive:true,force:true});
}
