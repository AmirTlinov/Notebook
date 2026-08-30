export interface VersionStamp {
  counter: number;
  actor: string;
}

interface PageSize {
  width: number;
  height: number;
}

export interface PageRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

type AgentElementKind = "markdown" | "web";
export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

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
  format: number;
  id: string;
  size: PageSize;
  drawingData: string;
  drawingStamp: VersionStamp;
  elements: AgentElement[];
  agentStamp: VersionStamp;
}

export interface Notebook {
  id: string;
  title: string;
  pageIDs: string[];
}

export interface WorkspaceIndex {
  format: number;
  notebooks: Notebook[];
  selectedNotebookID: string;
  selectedPageID: string;
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

export interface FreeNotebookPlacement {
  notebookID: string;
  center: WorldPoint;
  zIndex: number;
  stamp: VersionStamp;
}

export interface NotebookStack {
  id: string;
  center: WorldPoint;
  zIndex: number;
  notebookIDs: string[];
  stamp: VersionStamp;
}

export interface BoardDocument {
  format: number;
  freeNotebooks: FreeNotebookPlacement[];
  stacks: NotebookStack[];
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
  format: number;
  actions: SpatialInkAction[];
  stamp: VersionStamp;
}

export interface SessionPresence {
  format: number;
  mode: "board" | "cover" | "page";
  camera: SpatialCamera;
  viewport: SpatialPoint;
  focusedNotebookID?: string;
  openProgress: number;
}

export interface CurrentViewReceipt {
  format: number;
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
