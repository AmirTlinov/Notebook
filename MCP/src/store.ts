import { offsetWorld } from "./spatial.js";
import { AsyncLocalStorage } from "node:async_hooks";
import { createHash } from "node:crypto";
import { open } from "node:fs/promises";
import { constants } from "node:fs";
import { BridgeError, defaultSocketPath, runBridge } from "./bridge.js";
import type { BoardDocument, BoardHierarchy, CurrentViewReceipt, DocumentDocument, DocumentStateJournal,
  PageDocument, PageSize, SessionPresence, SpatialElement, SpatialInkJournal, SurfaceID, VersionStamp, WorldPoint,
  WorkspaceProjection, NotebookItemHeader } from "./domain.js";
import { canonicalPageSize, documentSpatialSize } from "./domain.js";

export class StoreError extends Error {}
export interface WorkspaceHeader {
  rootBoardID: string; stamp: VersionStamp; itemCount: number; cursor: number;
  selectedItemID?: string; selectedPageID?: string; boardRevision?: string; spatialInkStamp?: VersionStamp;
}
export type NotebookPageTarget = {kind:"index";index:number} | {kind:"page";id:string} | {kind:"selection"};
export interface NotebookPagePosition { itemID:string;pageID:string;index:number;visibleRoot:string;readCursor:string }
export interface NotebookPageHeader { workspaceID:string;item:NotebookItemHeader;visibleRoot:string;readCursor:string;selectedPageID?:string;selectedPageIndex?:number }
export interface NotebookPageWindow { header:NotebookPageHeader;pages:Array<{position:NotebookPagePosition;document:PageDocument}> }
export interface NotebookPageDirectory { header:NotebookPageHeader;pages:Array<{position:NotebookPagePosition;size:PageSize;drawingStamp:VersionStamp;agentStamp:VersionStamp}>;nextIndex?:number }
export interface SceneBounds { origin: WorldPoint; width: number; height: number }
export interface SceneWindow {
  header: WorkspaceHeader; boardID: string; items: NotebookItemHeader[]; boards: BoardHierarchy["boards"];
  documentPaper: Record<string, "a4" | "letter">; pageCounts: Record<string, number>; totalMatches: number; truncated: boolean;
}
export interface ScenePaintPage {
  revision: string; entries: Array<{kind:"item"|"element";id:string;zIndex:number}>; nextCursor: string | null;
}
export interface WorkingSet {
  header: WorkspaceHeader; items: NotebookItemHeader[]; boards: BoardHierarchy["boards"];
  pages: Record<string, PageDocument>; documents: Record<string, DocumentDocument>;
  states: Record<string, DocumentStateJournal>; ink: SpatialInkJournal;
}
export type ScopedSpatialInk = SpatialInkJournal & { readSurfaces: SurfaceID[] };
export interface ArtifactRequest {
  kind: "currentView" | "target" | "pageOverview" | "pageRegion";
  id?: string; regionID?: string; mode?: "faithful" | "ink"; expectedSHA256: string;
}
interface ReadQuery { kind: string; [key: string]: unknown }
interface ReadCut { socketPath: string; cursor: string; values: Map<string, Promise<unknown>>; conflicted: boolean }
const readCut = new AsyncLocalStorage<ReadCut>();
const idEquals = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** An addressed IPC reader, not a filesystem repository or a second migration owner. */
export class NotebookStore {
  constructor(readonly socketPath = defaultSocketPath()) {}

  command<T = Record<string, unknown>>(request: Record<string, unknown>): Promise<T> {
    return runBridge<T>(this.socketPath, request);
  }

  async withReadSnapshot<T>(operation: () => Promise<T>): Promise<T> {
    if (readCut.getStore()?.socketPath === this.socketPath) return operation();
    for (let attempt = 0; attempt < 3; attempt++) {
      const start = await this.command<{ cursor: string }>({ command: "read", queries: [] });
      const cut: ReadCut = { socketPath: this.socketPath, cursor: start.cursor, values: new Map(), conflicted: false };
      try {
        return await readCut.run(cut, async () => {
          const result = await operation();
          if (cut.conflicted) throw readConflict();
          await this.command({ command: "read", queries: [], expectedCursor: cut.cursor });
          return result;
        });
      } catch (error) {
        if (!cut.conflicted && !(error instanceof BridgeError && error.detail.code === "read_conflict")) throw error;
        if (attempt === 2) throw readConflict();
      }
    }
    throw readConflict();
  }

  async read<T>(query: ReadQuery): Promise<T> {
    const cut = readCut.getStore();
    const own = cut?.socketPath === this.socketPath ? cut : undefined;
    const key = JSON.stringify(query);
    const cached = own?.values.get(key);
    if (cached) return structuredClone(await cached) as T;
    const value = this.command<{ cursor: string; values: [T] }>({ command: "read", queries: [query],
      ...(own ? { expectedCursor: own.cursor } : {}) }).then(result => result.values[0]).catch(error => {
      if (own && error instanceof BridgeError && error.detail.code === "read_conflict") own.conflicted = true;
      throw error;
    });
    own?.values.set(key, value);
    return structuredClone(await value);
  }

  private async readValues<T>(queries: ReadQuery[]): Promise<T[]> {
    if (!queries.length) return [];
    if (queries.length > 32) throw new StoreError("Одна порция содержит не более 32 адресов.");
    const cut = readCut.getStore();
    const own = cut?.socketPath === this.socketPath ? cut : undefined;
    try {
      const result = await this.command<{cursor:string;values:T[]}>({command:"read",queries,
        ...(own ? {expectedCursor:own.cursor} : {})});
      return result.values;
    } catch (error) {
      if (own && error instanceof BridgeError && error.detail.code === "read_conflict") own.conflicted = true;
      throw error;
    }
  }

  readHeader(): Promise<WorkspaceHeader> { return this.read({ kind: "workspaceHeader" }); }
  readWorkingSet(itemIDs: string[] = [], pageIDs: string[] = [], boardIDs: string[] = [], surfaces: SurfaceID[] = []): Promise<WorkingSet> {
    return this.read({ kind: "workingSet", itemIDs, pageIDs, boardIDs, surfaces });
  }
  async readItem(id: string): Promise<NotebookItemHeader> {
    const item = await this.read<NotebookItemHeader | null>({kind:"itemHeader",id});
    if (!item) throw new StoreError("Предмет не найден.");
    return item;
  }

  /** Metadata for these IDs only. It is a projection, never a complete catalog. */
  async readWorkspaceProjection(itemIDs: string[] = []): Promise<WorkspaceProjection> {
    const header = await this.readHeader();
    const ids = [...new Set([...itemIDs, ...(header.selectedItemID ? [header.selectedItemID] : [])].map(id => id.toLowerCase()))];
    const items = await Promise.all(ids.map(id => this.readItem(id)));
    return { rootBoardID: header.rootBoardID, items, stamp: header.stamp,
      selectedItemID: header.selectedItemID ?? header.rootBoardID, ...(header.selectedPageID ? { selectedPageID: header.selectedPageID } : {}) };
  }
  readSceneWindow(boardID: string, bounds: SceneBounds, limit = 128, pinnedIDs: string[] = []): Promise<SceneWindow> {
    return this.read({ kind: "sceneWindow", id: boardID, bounds, limit, pinnedIDs });
  }
  async readBoard(boardID?: string): Promise<BoardDocument> {
    const presence = await this.readPresence();
    const id = boardID ?? presence.boardID;
    const window = await this.readSceneWindow(id, visibleBounds(presence));
    const node = window.boards.find(node => idEquals(node.id, id));
    if (!node) throw new StoreError("Доска не найдена.");
    return node.board;
  }
  async readItemBoard(itemID: string): Promise<BoardDocument> {
    const node = await this.read<BoardHierarchy["boards"][number] | null>({kind:"boardItem",id:itemID});
    if (!node) throw new StoreError("Предмет не принадлежит живой доске.");
    return node.board;
  }
  async readCoverElements(itemID: string, size: PageSize, cursor?: string, limit = 32) {
    const boardID = await this.read<string | null>({kind:"ownerBoard",id:itemID});
    if (!boardID) throw new StoreError("Обложка не принадлежит доске.");
    const bounds = {origin:{tileX:0,tileY:0,localX:0,localY:0},width:size.width,height:size.height};
    const page = await this.read<ScenePaintPage>({kind:"scenePaintOrder",id:boardID,coverID:itemID,
      bounds,paintCursor:cursor,limit});
    // One physical paint page is one SQL snapshot/IPC request, not 32 competing connections.
    const elements = await this.readValues<SpatialElement|null>(page.entries.filter(entry => entry.kind === "element")
      .map(entry => ({kind:"boardElement",id:boardID,elementID:entry.id})));
    return {elements:elements.filter((element):element is SpatialElement => !!element),
      coverage:{bounds,limit,revision:page.revision,nextCursor:page.nextCursor,truncated:page.nextCursor !== null}};
  }
  async readSpatialInk(surfaces?: SurfaceID[]): Promise<ScopedSpatialInk> {
    surfaces ??= [{ kind: "board", ownerID: (await this.readPresence()).boardID }];
    const ink = await this.read<SpatialInkJournal>({ kind: "spatialInk", surfaces });
    return { ...ink, readSurfaces: surfaces };
  }
  async readItemSizes(workspace: WorkspaceProjection, paper: Record<string, "a4" | "letter"> = {}): Promise<Map<string, PageSize>> {
    return new Map(workspace.items.map(item => {
      const size = paper[item.id.toLowerCase()] ?? paper[item.id];
      if (item.kind === "document" && !size) throw new StoreError("Размер документа отсутствует в проекции сцены.");
      return [item.id.toLowerCase(), item.kind === "document" ? documentSpatialSize(size!) : canonicalPageSize];
    }));
  }
  readPresence(): Promise<SessionPresence> { return this.read({ kind: "presence" }); }
  readPage(id: string): Promise<PageDocument> { return this.read({ kind: "page", id }); }
  readDocument(id: string): Promise<DocumentDocument> { return this.read({ kind: "document", id }); }
  readDocumentState(id: string): Promise<DocumentStateJournal> { return this.read({ kind: "documentState", id }); }
  readCollaborationContexts<T>(id?: string, limit = 20): Promise<T> { return this.read({ kind: "contexts", id, limit }); }
  readCollaborationActions<T>(contextID?: string, limit = 20): Promise<T> { return this.read({ kind: "actions", contextID, limit }); }
  readRuntime(): Promise<{ status: string; updatedAt: number } | null> { return this.read({ kind: "runtime" }); }
  async readCurrentViewReceipt(): Promise<CurrentViewReceipt> {
    const receipt = await this.read<CurrentViewReceipt | null>({ kind: "currentViewReceipt" });
    if (!receipt) throw new StoreError("Текущий вид ещё собирается в фоне.");
    return receipt;
  }
  readPageVisionReceipt(id: string, revision?: string): Promise<unknown | null> {
    return this.read({ kind: "pageVisionReceipt", id, revision });
  }
  readTargetRenderReceipt<T = Record<string, any>>(id: string): Promise<T | null> {
    return this.read({ kind: "targetRenderReceipt", id });
  }
  readActionSnapshots<T>(id: string): Promise<T> { return this.read({ kind: "actionSnapshots", id }); }
  readCurrentPage(): Promise<PageDocument> { return this.readWorkspacePage(); }
  async readWorkspacePage(pageID?: string): Promise<PageDocument> {
    const id = pageID ?? (await this.readHeader()).selectedPageID;
    if (!id) throw new StoreError("Сейчас выбран документ, а не лист тетради.");
    return this.readPage(id);
  }
  async readNotebookPage(notebookID: string, pageNumber?: number): Promise<PageDocument> {
    const header = await this.readHeader();
    const target: NotebookPageTarget = pageNumber !== undefined ? {kind:"index",index:pageNumber-1}
      : header.selectedItemID && idEquals(header.selectedItemID, notebookID) && header.selectedPageID
        ? {kind:"page",id:header.selectedPageID} : {kind:"index",index:0};
    const window = await this.readNotebookPages(notebookID,[target]);
    return window.pages[0]!.document;
  }

  readNotebookPages(id: string, pages: NotebookPageTarget[], visibleRoot?: string): Promise<NotebookPageWindow> {
    return this.read({kind:"notebookPages",id,pages,visibleRoot});
  }
  readNotebookDirectory(id: string, pageIndex: number, limit: number, visibleRoot?: string): Promise<NotebookPageDirectory> {
    return this.read({kind:"notebookDirectory",id,pageIndex,limit,visibleRoot});
  }
  readNotebookPosition(id: string, itemID?: string): Promise<NotebookPagePosition | null> {
    return this.read({kind:"notebookPosition",id,itemID});
  }

  async readCurrent(): Promise<
    | { kind: "notebook"; workspace: WorkspaceProjection; presence: SessionPresence; item: NotebookItemHeader; page: PageDocument }
    | { kind: "document"; workspace: WorkspaceProjection; presence: SessionPresence; item: NotebookItemHeader; document: DocumentDocument; state: DocumentStateJournal }
    | { kind: "board"; workspace: WorkspaceProjection; presence: SessionPresence; item: NotebookItemHeader }
  > {
    const presence = await this.readPresence();
    const workspace = await this.readWorkspaceProjection(presence.focusedItemID ? [presence.focusedItemID] : []);
    const id = presence.focusedItemID ?? workspace.selectedItemID;
    const item = workspace.items.find(candidate => idEquals(candidate.id, id))
      ?? { id: presence.boardID, kind: "board" as const, title: "", pageCount: 0 };
    if (presence.mode === "board" || item.kind === "board") return { kind: "board", workspace, presence, item };
    if (item.kind === "document") {
      const [document, state] = await Promise.all([this.readDocument(item.id), this.readDocumentState(item.id)]);
      return { kind: "document", workspace, presence, item, document, state };
    }
    const page = await this.readNotebookPage(item.id);
    return { kind: "notebook", workspace, presence, item, page };
  }

  async readArtifact(request: ArtifactRequest): Promise<Buffer> {
    const artifact = await this.command<{ path: string; sha256: string; byteCount: number; mimeType: string }>({ command: "artifact", artifact: request });
    if (artifact.sha256 !== request.expectedSHA256 || artifact.mimeType !== "image/png"
      || artifact.byteCount < 0 || artifact.byteCount > 64 * 1024 * 1024) throw new StoreError("Некорректная квитанция изображения.");
    // The path is granted by the authenticated owner, never assembled from tool input.
    const file = await open(artifact.path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size !== artifact.byteCount) throw new StoreError("Изображение обновляется.");
      const image = Buffer.alloc(artifact.byteCount);
      let offset = 0;
      while (offset < image.length) {
        const { bytesRead } = await file.read(image, offset, image.length - offset, offset);
        if (!bytesRead) throw new StoreError("Изображение ещё собирается.");
        offset += bytesRead;
      }
      if (createHash("sha256").update(image).digest("hex") !== request.expectedSHA256) throw new StoreError("Изображение обновляется.");
      return image;
    } finally { await file.close(); }
  }
}

function readConflict(): BridgeError {
  return new BridgeError({ code: "read_conflict", message: "Содержание меняется во время чтения. Повторите законченный запрос." });
}

export function workspaceProjection(window: SceneWindow): WorkspaceProjection {
  const header = window.header;
  return {rootBoardID:header.rootBoardID,stamp:header.stamp,items:window.items,
    selectedItemID:header.selectedItemID ?? header.rootBoardID,
    ...(header.selectedPageID ? {selectedPageID:header.selectedPageID} : {})};
}

export function visibleBounds(presence: SessionPresence): SceneBounds {
  const width = presence.viewport.x / presence.camera.scale;
  const height = presence.viewport.y / presence.camera.scale;
  return {origin:offsetWorld(presence.camera.center, -width / 2, -height / 2),width,height};
}

