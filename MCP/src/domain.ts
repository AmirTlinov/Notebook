interface VersionStamp {
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

interface Notebook {
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
