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

export type WorkspaceItemKind = "notebook" | "document";

export interface WorkspaceItem {
  id: string;
  kind: WorkspaceItemKind;
  title: string;
  pageIDs: string[];
}

export interface WorkspaceIndex {
  format: 2;
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
  ownerID?: string;
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

export interface BoardDocument {
  format: 2;
  freeItems: FreeItemPlacement[];
  stacks: WorkspaceItemStack[];
  elements: SpatialElement[];
  stamp: VersionStamp;
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
  format: 2;
  mode: "board" | "cover" | "page" | "document";
  camera: SpatialCamera;
  viewport: SpatialPoint;
  focusedItemID?: string;
  openProgress: number;
}

export interface CurrentViewReceipt {
  format: 2;
  workspaceStamp: VersionStamp;
  boardStamp: VersionStamp;
  spatialInkStamp: VersionStamp;
  presence: SessionPresence;
  renderViewport: SpatialPoint;
  pngSHA256: string;
  page?: {
    pageID: string;
    drawingStamp: VersionStamp;
    agentStamp: VersionStamp;
  };
  document?: {
    documentID: string;
    contentStamp: VersionStamp;
    stateStamp: VersionStamp;
  };
}

export function revision(stamp: VersionStamp): string {
  return `${stamp.counter}@${stamp.actor.toLowerCase()}`;
}

export function publicPage(page: PageDocument): object {
  return {
    id: page.id,
    size: page.size,
    drawingRevision: revision(page.drawingStamp),
    agentRevision: revision(page.agentStamp),
    elements: page.elements,
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
    blocks: document.blocks,
    state: Object.fromEntries(state.records.map((record) => [record.id, record.value])),
  };
}
