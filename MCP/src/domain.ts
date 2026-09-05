import { createHash } from "node:crypto";

export interface VersionStamp {
  counter: number;
  actor: string;
}

export interface PageSize {
  width: number;
  height: number;
}

export interface PageRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

export type AgentElementKind = "markdown" | "web";

export interface AgentElement {
  id: string;
  kind: AgentElementKind;
  frame: PageRect;
  source: string;
  html: string;
  css: string;
  javaScript: string;
  state: JSONValue;
}

export interface PageDocument {
  format: 1;
  id: string;
  size: PageSize;
  drawingData: string;
  drawingStamp: VersionStamp;
  elements: AgentElement[];
  agentStamp: VersionStamp;
}

export type WorkspaceItemKind = "notebook" | "document" | "board";

export interface WorkspaceItem {
  id: string;
  kind: WorkspaceItemKind;
  title: string;
  pageIDs: string[];
}

export interface WorkspaceIndex {
  format: 3;
  rootBoardID: string;
  items: WorkspaceItem[];
  selectedItemID: string;
  selectedPageID?: string;
  stamp: VersionStamp;
}

export type DocumentBlockKind = "markdown" | "latex" | "interactive";
export type DocumentPaperSize = "a4" | "letter";

export interface DocumentBlock {
  id: string;
  kind: DocumentBlockKind;
  source: string;
  html: string;
  css: string;
  javaScript: string;
  initialState: JSONValue;
  height: number;
}

export interface DocumentDocument {
  format: 2;
  id: string;
  paperSize: DocumentPaperSize;
  preamble: string;
  blocks: DocumentBlock[];
  contentStamp: VersionStamp;
}

export interface DocumentStateRecord {
  id: string;
  value: JSONValue;
  stamp: VersionStamp;
}

export interface DocumentStateJournal {
  format: 1;
  id: string;
  records: DocumentStateRecord[];
  stamp: VersionStamp;
}

export interface WorldPoint {
  tileX: number;
  tileY: number;
  localX: number;
  localY: number;
}

export interface SpatialPoint {
  x: number;
  y: number;
}

export interface SpatialCamera {
  center: WorldPoint;
  scale: number;
}

export interface SurfaceID {
  kind: "board" | "cover" | "page";
  ownerID: string;
}

export type SpatialElementKind = "nativeText" | "markdown" | "web";

export interface NativeTextStyle {
  fontSize: number;
  weight: number;
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

export interface SpatialElement {
  id: string;
  surface: SurfaceID;
  kind: SpatialElementKind;
  frame: PageRect;
  worldOrigin?: WorldPoint;
  source: string;
  html: string;
  css: string;
  javaScript: string;
  state: JSONValue;
  textStyle: NativeTextStyle;
  stamp: VersionStamp;
}

export interface FreeItemPlacement {
  itemID: string;
  center: WorldPoint;
  zIndex: number;
  stamp: VersionStamp;
}

export interface WorkspaceItemStack {
  id: string;
  center: WorldPoint;
  zIndex: number;
  itemIDs: string[];
  stamp: VersionStamp;
}

export const maximumStackItemCount = 5;
export const minimumCameraScale = 0.0125;
export const maximumCameraScale = 4;
export const canonicalPageSize: PageSize = { width: 834, height: 1_194 };

/** Same physical point conversion as WorkspaceItemGeometry.document in Swift. */
export function documentSpatialSize(paper: DocumentPaperSize): PageSize {
  const postScript = paper === "a4"
    ? { width: 595.275590551, height: 841.88976378 }
    : { width: 612, height: 792 };
  return { width: postScript.width * 132 / 72, height: postScript.height * 132 / 72 };
}

export interface BoardDocument {
  format: 2;
  freeItems: FreeItemPlacement[];
  stacks: WorkspaceItemStack[];
  elements: SpatialElement[];
  stamp: VersionStamp;
}

export interface BoardNode {
  id: string;
  board: BoardDocument;
  portalCamera?: SpatialCamera;
  portalStamp?: VersionStamp;
}

export interface BoardHierarchy {
  format: 1;
  rootBoardID: string;
  boards: BoardNode[];
  stamp: VersionStamp;
}

export function boardHierarchyRevision(hierarchy: BoardHierarchy): string {
  const rows = [...hierarchy.boards]
    .sort((a, b) => {
      const left = a.id.toLowerCase();
      const right = b.id.toLowerCase();
      return left < right ? -1 : left > right ? 1 : 0;
    })
    .map((node) => `${node.id.toLowerCase()}:${revision(node.board.stamp)}:`
      + revision(node.portalStamp ?? { counter: 0, actor: node.board.stamp.actor }));
  const source = ["board-v1", hierarchy.rootBoardID.toLowerCase(), ...rows].join("\n") + "\n";
  return createHash("sha256").update(source).digest("hex");
}

export interface SpatialInkSample {
  point: SpatialPoint;
  worldPoint?: WorldPoint;
  timeOffset: number;
  width: number;
  opacity: number;
  force: number;
  azimuth: number;
  altitude: number;
}

export interface SpatialInkSpan {
  surface: SurfaceID;
  samples: SpatialInkSample[];
}

export interface SpatialInkAction {
  id: string;
  tool: "pen" | "eraser";
  color: { red: number; green: number; blue: number };
  spans: SpatialInkSpan[];
  stamp: VersionStamp;
  isActive: boolean;
  stateStamp: VersionStamp;
}

export interface SpatialInkJournal {
  format: 1;
  actions: SpatialInkAction[];
  stamp: VersionStamp;
}

export interface SessionPresence {
  format: 4;
  boardID: string;
  mode: "board" | "cover" | "page" | "document";
  camera: SpatialCamera;
  viewport: SpatialPoint;
  focusedItemID?: string;
  openProgress: number;
  documentPageIndex: number;
}

export type CurrentViewSurfaceRevision =
  | { kind: "board"; boardID: string }
  | { kind: "cover"; itemID: string }
  | {
    kind: "page";
    itemID: string;
    revision: {
      pageID: string;
      drawingStamp: VersionStamp;
      agentStamp: VersionStamp;
    };
    snapshotPNG_SHA256: string;
  }
  | {
    kind: "document";
    revision: {
      documentID: string;
      contentStamp: VersionStamp;
      stateStamp: VersionStamp;
    };
    pageIndex: number;
    snapshotPNG_SHA256: string;
  };

export interface CurrentViewReceipt {
  format: 6;
  workspaceStamp: VersionStamp;
  boardRevision: string;
  spatialInkStamp: VersionStamp;
  presence: SessionPresence;
  renderViewport: SpatialPoint;
  surface: CurrentViewSurfaceRevision;
  pngSHA256: string;
}

export function revision(stamp: VersionStamp): string {
  return `${stamp.counter}@${stamp.actor.toLowerCase()}`;
}

export function publicPage(page: PageDocument, options: { includeSource?: boolean; elementID?: string | undefined } = {}): object {
  return {
    id: page.id,
    size: page.size,
    drawingRevision: revision(page.drawingStamp),
    agentRevision: revision(page.agentStamp),
    elements: page.elements.filter(element => !options.elementID || element.id === options.elementID).map((element) => ({
      id: element.id,
      kind: element.kind,
      frame: element.frame,
      sourcePreview: element.source.slice(0, 160),
      sourceCharacterCount: element.source.length,
      ...(options.includeSource ? { source: element.source, html: element.html, css: element.css,
        javascript: element.javaScript, state: element.state } : {}),
    })),
  };
}

export function publicDocument(
  document: DocumentDocument,
  state: DocumentStateJournal,
): object {
  return {
    id: document.id,
    paperSize: document.paperSize,
    contentRevision: revision(document.contentStamp),
    stateRevision: revision(state.stamp),
    preamble: document.preamble,
    blocks: document.blocks.map((block) => block.kind === "interactive"
      ? {
          id: block.id,
          kind: block.kind,
          html: block.html,
          css: block.css,
          javascript: block.javaScript,
          initial_state: block.initialState,
          height: block.height,
        }
      : {
          id: block.id,
          kind: block.kind,
          source: block.source,
        }),
    state: Object.fromEntries(state.records.map((record) => [record.id, record.value])),
  };
}
