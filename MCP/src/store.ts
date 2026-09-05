import { existsSync, mkdirSync, renameSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { AsyncLocalStorage } from "node:async_hooks";
import { runBridge } from "./bridge.js";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import type {
  AgentElement,
  BoardDocument,
  BoardHierarchy,
  CurrentViewReceipt,
  DocumentBlock,
  DocumentDocument,
  DocumentStateJournal,
  PageDocument,
  PageRect,
  PageSize,
  SessionPresence,
  SpatialElement,
  SpatialInkJournal,
  SurfaceID,
  VersionStamp,
  WorldPoint,
  WorkspaceIndex,
  WorkspaceItem,
} from "./domain.js";
import {
  maximumCameraScale,
  maximumStackItemCount,
  minimumCameraScale,
  canonicalPageSize,
  documentSpatialSize,
} from "./domain.js";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAXIMUM_PAGE_DIMENSION = 2_048;
const WORLD_TILE_SIZE = (132 / 2.54 / 2) * 256;
const readSnapshot = new AsyncLocalStorage<{ root: string; files: Record<string, unknown> }>();
export const ROOT_BOARD_ID = "7e7a0000-0000-4000-8000-000000000003";

export class StoreError extends Error {}

export class NotebookStore {
  readonly root: string;

  constructor(root = defaultStoreRoot()) {
    this.root = root;
  }

  async withReadSnapshot<T>(operation: () => Promise<T>): Promise<T> {
    if (readSnapshot.getStore()?.root === this.root) return operation();
    const files = await runBridge<Record<string, unknown>>(this.root, { command: "snapshot" });
    return readSnapshot.run({ root: this.root, files }, operation);
  }

  async readCollaborationContexts<T>(): Promise<T> {
    return this.withReadSnapshot(() => readJSON<T>(join(this.root, "collaboration/contexts.json"), "контекстов"));
  }

  async readCollaborationActions<T>(): Promise<T> {
    return this.withReadSnapshot(() => readJSON<T>(join(this.root, "collaboration/actions.json"), "ходов"));
  }

  get indexPath(): string {
    return join(this.root, "workspace.json");
  }

  get pagesPath(): string {
    return join(this.root, "pages");
  }

  get documentsPath(): string {
    return join(this.root, "documents");
  }

  get documentStatesPath(): string {
    return join(this.root, "document-states");
  }

  get boardPath(): string {
    return join(this.root, "board.json");
  }

  get spatialInkPath(): string {
    return join(this.root, "spatial-ink.json");
  }

  get presencePath(): string {
    return join(this.root, "last-context.json");
  }

  get currentViewPath(): string {
    return join(this.root, "previews", "current-view.png");
  }

  get currentViewReceiptPath(): string {
    return join(this.root, "previews", "current-view.revision");
  }

  pagePath(pageID: string): string {
    assertUUID(pageID, "page_id");
    return join(this.pagesPath, `${pageID.toLowerCase()}.json`);
  }

  documentPath(documentID: string): string {
    assertUUID(documentID, "document_id");
    return join(this.documentsPath, `${documentID.toLowerCase()}.json`);
  }

  documentStatePath(documentID: string): string {
    assertUUID(documentID, "document_id");
    return join(this.documentStatesPath, `${documentID.toLowerCase()}.json`);
  }

  previewPath(pageID: string): string {
    assertUUID(pageID, "page_id");
    return join(this.root, "previews", `${pageID.toLowerCase()}.png`);
  }

  async readWorkspace(): Promise<WorkspaceIndex> {
    const stored = await readJSON<unknown>(this.indexPath, "workspace");
    const workspace = migrateWorkspace(stored);
    validateWorkspace(workspace);
    return workspace;
  }

  async readPage(pageID: string): Promise<PageDocument> {
    const page = await readJSON<unknown>(this.pagePath(pageID), "page");
    validatePage(page);
    if (page.id.toLowerCase() !== pageID.toLowerCase()) {
      throw new StoreError("page.id не совпадает с именем файла.");
    }
    return page;
  }

  async readBoardHierarchy(workspace?: WorkspaceIndex): Promise<BoardHierarchy> {
    const resolvedWorkspace = workspace ?? await this.readWorkspace();
    const stored = await readJSON<unknown>(this.boardPath, "board");
    const board = migrateBoard(stored, resolvedWorkspace);
    validateBoardHierarchy(board, resolvedWorkspace);
    return board;
  }

  async readBoard(
    workspace?: WorkspaceIndex,
    boardID?: string,
  ): Promise<BoardDocument> {
    const resolvedWorkspace = workspace ?? await this.readWorkspace();
    const hierarchy = await this.readBoardHierarchy(resolvedWorkspace);
    const resolvedBoardID = boardID ?? (await this.readPresence()).boardID;
    const node = hierarchy.boards.find((candidate) =>
      sameID(candidate.id, resolvedBoardID)
    );
    if (!node) throw new StoreError("Текущая вложенная доска не найдена.");
    return structuredClone(node.board);
  }

  async readItemBoard(
    itemID: string,
    workspace?: WorkspaceIndex,
  ): Promise<BoardDocument> {
    const resolvedWorkspace = workspace ?? await this.readWorkspace();
    const hierarchy = await this.readBoardHierarchy(resolvedWorkspace);
    const node = hierarchy.boards.find((candidate) =>
      candidate.board.freeItems.some((placement) => sameID(placement.itemID, itemID))
      || candidate.board.stacks.some((stack) =>
        stack.itemIDs.some((candidateID) => sameID(candidateID, itemID))
      )
    );
    if (!node) throw new StoreError("Предмет не принадлежит живой доске.");
    return structuredClone(node.board);
  }

  async readSpatialInk(): Promise<SpatialInkJournal> {
    const stored = await readJSON<unknown>(this.spatialInkPath, "spatial ink");
    const journal = migrateSpatialInk(stored);
    validateSpatialInk(journal);
    return journal;
  }

  async readItemSizes(workspace: WorkspaceIndex): Promise<Map<string, PageSize>> {
    return new Map(await Promise.all(workspace.items.map(async (item) => [
      item.id.toLowerCase(),
      item.kind === "document"
        ? documentSpatialSize((await this.readDocument(item.id)).paperSize)
        : canonicalPageSize,
    ] as const)));
  }

  async readPresence(): Promise<SessionPresence> {
    const stored = await readJSON<unknown>(this.presencePath, "current context");
    const presence = migratePresence(stored);
    validatePresence(presence);
    return presence;
  }

  async readCurrentViewReceipt(): Promise<CurrentViewReceipt> {
    const stored = await readJSON<unknown>(
      this.currentViewReceiptPath,
      "current view receipt",
    );
    const receipt = isRecord(stored)
      ? { ...stored, presence: migratePresence(stored.presence) }
      : stored;
    validateCurrentViewReceipt(receipt);
    return receipt;
  }

  async readCurrentPage(): Promise<PageDocument> {
    return this.readWorkspacePage();
  }

  async readWorkspacePage(pageID?: string): Promise<PageDocument> {
    const workspace = await this.readWorkspace();
    const resolvedPageID = pageID ?? workspace.selectedPageID;
    if (!resolvedPageID) {
      throw new StoreError("Сейчас выбран документ, а не лист тетради.");
    }
    const owner = workspace.items.find((item) =>
      item.kind === "notebook"
        && item.pageIDs.some((candidate) => sameID(candidate, resolvedPageID))
    );
    if (!owner) throw new StoreError("Лист не принадлежит живой тетради.");
    return this.readPage(resolvedPageID);
  }

  async readCurrent(): Promise<
    | {
      kind: "notebook";
      workspace: WorkspaceIndex;
      presence: SessionPresence;
      item: WorkspaceItem;
      page: PageDocument;
    }
    | {
      kind: "document";
      workspace: WorkspaceIndex;
      presence: SessionPresence;
      item: WorkspaceItem;
      document: DocumentDocument;
      state: DocumentStateJournal;
    }
    | {
      kind: "board";
      workspace: WorkspaceIndex;
      presence: SessionPresence;
      item: WorkspaceItem;
    }
  > {
    const workspace = await this.readWorkspace();
    const presence = await this.readPresence();
    const item = workspace.items.find(candidate => presence.focusedItemID
      && sameID(candidate.id, presence.focusedItemID)) ?? selectedItem(workspace);
    if (presence.mode === "board" || item.kind === "board") {
      return { kind: "board", workspace, presence, item };
    }
    if (item.kind === "document") {
      const [document, state] = await Promise.all([
        this.readDocument(item.id),
        this.readDocumentState(item.id),
      ]);
      return { kind: "document", workspace, presence, item, document, state };
    }
    const pageID = sameID(item.id, workspace.selectedItemID)
      ? workspace.selectedPageID : item.pageIDs[0];
    if (!pageID) throw new StoreError("У выбранной тетради нет выбранного листа.");
    return {
      kind: "notebook",
      workspace,
      presence,
      item,
      page: await this.readPage(pageID),
    };
  }

  async readDocument(documentID: string): Promise<DocumentDocument> {
    const stored = await readJSON<unknown>(
      this.documentPath(documentID),
      "document",
    );
    const document = normalizeDocument(stored);
    validateDocument(document);
    if (!sameID(document.id, documentID)) {
      throw new StoreError("document.id не совпадает с именем файла.");
    }
    return document;
  }

  async readDocumentState(documentID: string): Promise<DocumentStateJournal> {
    const state = await readJSON<unknown>(
      this.documentStatePath(documentID),
      "document state",
    );
    validateDocumentState(state);
    if (!sameID(state.id, documentID)) {
      throw new StoreError("document state id не совпадает с именем файла.");
    }
    return state;
  }

}

function defaultStoreRoot(): string {
  if (process.env.NOTEBOOK_HOME) return process.env.NOTEBOOK_HOME;

  const applicationSupport = join(homedir(), "Library", "Application Support");
  const currentRoot = join(applicationSupport, "Notebook");
  migrateLegacyStore(join(applicationSupport, "Tetrad"), currentRoot);
  return currentRoot;
}

export function migrateLegacyStore(legacyRoot: string, currentRoot: string): void {
  if (existsSync(currentRoot) || !existsSync(legacyRoot)) return;

  mkdirSync(dirname(currentRoot), { recursive: true });
  try {
    renameSync(legacyRoot, currentRoot);
  } catch (error) {
    if (!existsSync(currentRoot)) throw error;
  }
}

export function assertFrame(frame: PageRect, page: PageDocument): void {
  for (const [name, value] of Object.entries(frame)) {
    if (!Number.isFinite(value)) throw new StoreError(`frame.${name} должен быть числом.`);
  }
  if (frame.width <= 0 || frame.height <= 0) {
    throw new StoreError("Ширина и высота элемента должны быть больше нуля.");
  }
  if (
    frame.x < 0 ||
    frame.y < 0 ||
    frame.x + frame.width > page.size.width ||
    frame.y + frame.height > page.size.height
  ) {
    throw new StoreError(
      `Элемент должен лежать внутри листа ${page.size.width}x${page.size.height}.`,
    );
  }
}

export function assertSpatialFrame(
  frame: PageRect,
  surface: { kind: "board" | "cover" | "page" },
  coverSize?: PageSize,
): void {
  for (const [name, value] of Object.entries(frame)) {
    if (!Number.isFinite(value)) throw new StoreError(`frame.${name} должен быть числом.`);
  }
  if (frame.width <= 0 || frame.height <= 0) {
    throw new StoreError("Ширина и высота элемента должны быть больше нуля.");
  }
  if (
    surface.kind === "cover"
    && (frame.x < 0 || frame.y < 0 || (coverSize !== undefined
      && (frame.x + frame.width > coverSize.width || frame.y + frame.height > coverSize.height)))
  ) {
    throw new StoreError(`Элемент обложки должен лежать внутри её физического размера${coverSize ? ` ${coverSize.width}x${coverSize.height}` : ""}.`);
  }
}

function validateElements(elements: unknown, page: PageDocument): asserts elements is AgentElement[] {
  if (!Array.isArray(elements)) throw new StoreError("Список элементов поврежден.");
  const ids = new Set<string>();
  for (const element of elements) {
    if (!isRecord(element)) throw new StoreError("Элемент страницы поврежден.");
    if (typeof element.id !== "string") throw new StoreError("id элемента поврежден.");
    if (!element.id.trim()) throw new StoreError("id элемента должен быть непустым.");
    if (ids.has(element.id)) throw new StoreError(`Повторяется id элемента: ${element.id}`);
    ids.add(element.id);
    if (!isFrame(element.frame)) throw new StoreError(`frame элемента ${element.id} поврежден.`);
    assertFrame(element.frame, page);
    if (element.kind !== "markdown" && element.kind !== "web") {
      throw new StoreError(`Неизвестный вид элемента: ${String(element.kind)}`);
    }
    for (const field of ["source", "html", "css", "javaScript"] as const) {
      if (typeof element[field] !== "string") {
        throw new StoreError(`${field} элемента ${element.id} поврежден.`);
      }
    }
    if (!("state" in element) || !isJSONValue(element.state)) {
      throw new StoreError(`state элемента ${element.id} поврежден.`);
    }
  }
}

function validatePage(page: unknown): asserts page is PageDocument {
  if (!isRecord(page)) throw new StoreError("Страница повреждена.");
  if (page.format !== 1) throw new StoreError(`Неизвестный формат страницы: ${page.format}`);
  if (typeof page.id !== "string") throw new StoreError("page.id поврежден.");
  assertUUID(page.id, "page.id");
  if (
    !isRecord(page.size) ||
    !isPageDimension(page.size.width) ||
    !isPageDimension(page.size.height)
  ) {
    throw new StoreError("Размер страницы поврежден.");
  }
  if (typeof page.drawingData !== "string" || !isCanonicalBase64(page.drawingData)) {
    throw new StoreError("Данные Pencil повреждены.");
  }
  validateStamp(page.drawingStamp, "drawingStamp");
  validateStamp(page.agentStamp, "agentStamp");
  const typedPage = page as unknown as PageDocument;
  validateElements(typedPage.elements, typedPage);
}

function migrateWorkspace(value: unknown): unknown {
  if (!isRecord(value)) return value;
  if (value.format === 3) return value;
  if (value.format === 2) {
    return { ...value, format: 3, rootBoardID: ROOT_BOARD_ID };
  }
  if (value.format !== 1 || !Array.isArray(value.notebooks)
    || typeof value.selectedNotebookID !== "string") return value;
  return {
    format: 3,
    rootBoardID: ROOT_BOARD_ID,
    items: value.notebooks.map((notebook) => isRecord(notebook)
      ? { ...notebook, kind: "notebook" }
      : notebook),
    selectedItemID: value.selectedNotebookID,
    ...(typeof value.selectedPageID === "string"
      ? { selectedPageID: value.selectedPageID }
      : {}),
    stamp: value.stamp,
  };
}

function migrateBoard(value: unknown, workspace: WorkspaceIndex): unknown {
  if (!isRecord(value)) return value;
  if (value.format === 1 && Array.isArray(value.boards)) return value;
  let document: unknown = value;
  if (value.format === 1 && Array.isArray(value.freeNotebooks)
    && Array.isArray(value.stacks)) {
    document = {
      format: 2,
      freeItems: value.freeNotebooks.map((placement) => isRecord(placement)
        ? {
          itemID: placement.notebookID,
          center: placement.center,
          zIndex: placement.zIndex,
          stamp: placement.stamp,
        }
        : placement),
      stacks: value.stacks.map((stack) => isRecord(stack)
        ? {
          id: stack.id,
          center: stack.center,
          zIndex: stack.zIndex,
          itemIDs: stack.notebookIDs,
          stamp: stack.stamp,
        }
        : stack),
      elements: value.elements,
      stamp: value.stamp,
    };
  }
  if (!isRecord(document) || document.format !== 2) return value;
  const root = workspace.rootBoardID;
  return {
    format: 1,
    rootBoardID: root,
    boards: [{
      id: root,
      board: migrateBoardSurfaceOwners(document, root),
    }],
    stamp: document.stamp,
  };
}

function migrateBoardSurfaceOwners(
  board: Record<string, unknown>,
  boardID: string,
): Record<string, unknown> {
  return {
    ...board,
    elements: Array.isArray(board.elements)
      ? board.elements.map((element) => isRecord(element)
        && isRecord(element.surface)
        && element.surface.kind === "board"
        && typeof element.surface.ownerID !== "string"
        ? { ...element, surface: { ...element.surface, ownerID: boardID } }
        : element)
      : board.elements,
  };
}

// Before nested boards, an omitted board owner named the permanent root.
// Explicit owners, cover owners, samples, action IDs and stamps retain their values.
function migrateSpatialInk(value: unknown): unknown {
  if (!isRecord(value) || value.format !== 1 || !Array.isArray(value.actions)) return value;
  return {
    ...value,
    actions: value.actions.map((action) => isRecord(action) && Array.isArray(action.spans)
      ? {
        ...action,
        spans: action.spans.map((span) => isRecord(span)
          && isRecord(span.surface)
          && span.surface.kind === "board"
          && span.surface.ownerID == null
          ? { ...span, surface: { ...span.surface, ownerID: ROOT_BOARD_ID } }
          : span),
      }
      : action),
  };
}

function migratePresence(value: unknown): unknown {
  if (!isRecord(value)) return value;
  if (value.format === 4) return value;
  if (value.format === 3) {
    return { ...value, format: 4, boardID: ROOT_BOARD_ID };
  }
  if (value.format === 2) {
    return {
      ...value,
      format: 4,
      boardID: ROOT_BOARD_ID,
      documentPageIndex: 0,
    };
  }
  if (value.format === 1) {
    return {
      format: 4,
      boardID: ROOT_BOARD_ID,
      mode: value.mode,
      camera: value.camera,
      viewport: value.viewport,
      ...(typeof value.focusedNotebookID === "string"
        ? { focusedItemID: value.focusedNotebookID }
        : {}),
      openProgress: value.openProgress,
      documentPageIndex: 0,
    };
  }
  return value;
}

function selectedItem(workspace: WorkspaceIndex): WorkspaceItem {
  const item = workspace.items.find(
    (candidate) => sameID(candidate.id, workspace.selectedItemID),
  );
  if (!item) throw new StoreError("Выбранный элемент workspace не найден.");
  return item;
}

function validateDocument(value: unknown): asserts value is DocumentDocument {
  if (!isRecord(value) || value.format !== 2 || typeof value.id !== "string"
    || (value.paperSize !== "a4" && value.paperSize !== "letter")) {
    throw new StoreError("Документ повреждён.");
  }
  assertUUID(value.id, "document.id");
  if (typeof value.preamble !== "string" || value.preamble.length > 200_000
    || !Array.isArray(value.blocks) || value.blocks.length > 512) {
    throw new StoreError("Содержимое документа повреждено.");
  }
  validateStamp(value.contentStamp, "document.contentStamp");
  const ids = new Set<string>();
  for (const block of value.blocks) validateDocumentBlock(block, ids);
}

function normalizeDocument(value: unknown): unknown {
  if (isRecord(value) && value.format === 1 && !("paperSize" in value)) {
    return { ...value, format: 2, paperSize: "a4" };
  }
  return value;
}

function validateDocumentBlock(value: unknown, ids: Set<string>): asserts value is DocumentBlock {
  if (!isRecord(value) || typeof value.id !== "string" || !value.id.trim()
    || value.id.length > 120 || ids.has(value.id)) {
    throw new StoreError("id блока документа повреждён или повторяется.");
  }
  ids.add(value.id);
  if (value.kind !== "markdown" && value.kind !== "latex"
    && value.kind !== "interactive") {
    throw new StoreError(`Неизвестный вид блока: ${String(value.kind)}`);
  }
  for (const field of ["source", "html", "css", "javaScript"] as const) {
    if (typeof value[field] !== "string" || value[field].length > 1_000_000) {
      throw new StoreError(`${field} блока ${value.id} повреждено.`);
    }
  }
  if (!("initialState" in value) || !isJSONValue(value.initialState)
    || typeof value.height !== "number" || !Number.isFinite(value.height)) {
    throw new StoreError(`Параметры блока ${value.id} повреждены.`);
  }
  if (value.kind === "interactive") {
    if (value.source !== value.html || value.height < 48 || value.height > 2_048) {
      throw new StoreError(`Интерактивный блок ${value.id} повреждён.`);
    }
  } else if (value.html !== "" || value.css !== "" || value.javaScript !== ""
    || !isEmptyObject(value.initialState)) {
    throw new StoreError(`Текстовый блок ${value.id} содержит лишние поля.`);
  }
}

function validateDocumentState(value: unknown): asserts value is DocumentStateJournal {
  if (!isRecord(value) || value.format !== 1 || typeof value.id !== "string"
    || !Array.isArray(value.records)) {
    throw new StoreError("Состояние документа повреждено.");
  }
  assertUUID(value.id, "documentState.id");
  validateStamp(value.stamp, "documentState.stamp");
  const ids = new Set<string>();
  for (const record of value.records) {
    if (!isRecord(record) || typeof record.id !== "string" || !record.id
      || record.id.length > 120 || ids.has(record.id)
      || !("value" in record) || !isJSONValue(record.value)) {
      throw new StoreError("Запись состояния документа повреждена.");
    }
    ids.add(record.id);
    validateStamp(record.stamp, `documentState.${record.id}.stamp`);
    if (compareStamp(record.stamp as VersionStamp, value.stamp as VersionStamp) > 0) {
      throw new StoreError("Запись состояния новее журнала документа.");
    }
  }
}

function validateWorkspace(value: unknown): asserts value is WorkspaceIndex {
  if (!isRecord(value)) throw new StoreError("workspace поврежден.");
  if (value.format !== 3) {
    throw new StoreError(`Неизвестный формат workspace: ${String(value.format)}`);
  }
  if (!Array.isArray(value.items) || value.items.length === 0) {
    throw new StoreError("В workspace нет рабочих элементов.");
  }
  if (typeof value.selectedItemID !== "string") {
    throw new StoreError("Выбор workspace поврежден.");
  }
  const selectedItemID = value.selectedItemID;
  if (typeof value.rootBoardID !== "string") {
    throw new StoreError("Корневая доска workspace повреждена.");
  }
  assertUUID(value.rootBoardID, "rootBoardID");
  assertUUID(selectedItemID, "selectedItemID");
  validateOptionalUUID(value.selectedPageID, "selectedPageID");
  validateStamp(value.stamp, "workspace.stamp");

  const itemIDs = new Set<string>();
  const pageIDs = new Set<string>();
  let selectedItem: Record<string, unknown> | undefined;
  for (const item of value.items) {
    if (!isRecord(item) || typeof item.id !== "string") {
      throw new StoreError("Элемент workspace повреждён.");
    }
    assertUUID(item.id, "item.id");
    const itemID = item.id.toLowerCase();
    if (itemIDs.has(itemID)) throw new StoreError(`Повторяется item.id: ${item.id}`);
    itemIDs.add(itemID);
    if (item.kind !== "notebook" && item.kind !== "document"
      && item.kind !== "board") {
      throw new StoreError(`Вид элемента ${item.id} повреждён.`);
    }
    if (typeof item.title !== "string" || item.title.length > 240) {
      throw new StoreError(`Название элемента ${item.id} повреждено.`);
    }
    if (!Array.isArray(item.pageIDs)
      || (item.kind === "notebook" && item.pageIDs.length === 0)
      || (item.kind !== "notebook" && item.pageIDs.length !== 0)) {
      throw new StoreError(`Листы элемента ${item.id} повреждены.`);
    }
    for (const pageID of item.pageIDs) {
      if (typeof pageID !== "string") throw new StoreError("pageID поврежден.");
      assertUUID(pageID, "pageID");
      const normalized = pageID.toLowerCase();
      if (pageIDs.has(normalized)) throw new StoreError(`Повторяется pageID: ${pageID}`);
      pageIDs.add(normalized);
    }
    if (itemID === selectedItemID.toLowerCase()) selectedItem = item;
  }
  if (!selectedItem) throw new StoreError("Выбранный элемент не найден.");
  if (selectedItem.kind === "notebook") {
    const selectedPageID = value.selectedPageID;
    if (typeof selectedPageID !== "string"
      || !(selectedItem.pageIDs as unknown[]).some(
        (pageID) => typeof pageID === "string" && sameID(pageID, selectedPageID),
      )) {
      throw new StoreError("Выбранный лист не принадлежит выбранной тетради.");
    }
  } else if (value.selectedPageID !== undefined && value.selectedPageID !== null) {
    throw new StoreError("Документ не может выбирать тетрадный лист.");
  }
}

function validateBoardDocument(
  value: unknown,
  expectedItemIDs: Set<string>,
  boardID: string,
): asserts value is BoardDocument {
  if (!isRecord(value) || value.format !== 2) {
    throw new StoreError("Доска повреждена или имеет неизвестный формат.");
  }
  validateStamp(value.stamp, "board.stamp");
  if (!Array.isArray(value.freeItems) || !Array.isArray(value.stacks)
    || !Array.isArray(value.elements)) {
    throw new StoreError("Содержимое доски повреждено.");
  }
  const ownedItemIDs = new Set<string>();
  for (const placement of value.freeItems) {
    if (!isRecord(placement) || typeof placement.itemID !== "string") {
      throw new StoreError("Размещение элемента повреждено.");
    }
    assertUUID(placement.itemID, "placement.itemID");
    validateWorldPoint(placement.center, "placement.center");
    validateZIndex(placement.zIndex, "placement.zIndex");
    validateStamp(placement.stamp, "placement.stamp");
    addOwnedItem(ownedItemIDs, placement.itemID);
  }
  const stackIDs = new Set<string>();
  for (const stack of value.stacks) {
    if (!isRecord(stack) || typeof stack.id !== "string") {
      throw new StoreError("Стопка повреждена.");
    }
    assertUUID(stack.id, "stack.id");
    const stackID = stack.id.toLowerCase();
    if (stackIDs.has(stackID)) throw new StoreError(`Повторяется stack.id: ${stack.id}`);
    stackIDs.add(stackID);
    validateWorldPoint(stack.center, "stack.center");
    validateZIndex(stack.zIndex, "stack.zIndex");
    validateStamp(stack.stamp, "stack.stamp");
    if (!Array.isArray(stack.itemIDs) || stack.itemIDs.length < 2
      || stack.itemIDs.length > maximumStackItemCount) {
      throw new StoreError(
        `В стопке должно быть от двух до ${maximumStackItemCount} элементов.`,
      );
    }
    for (const itemID of stack.itemIDs) {
      if (typeof itemID !== "string") throw new StoreError("itemID стопки повреждён.");
      assertUUID(itemID, "stack.itemID");
      addOwnedItem(ownedItemIDs, itemID);
    }
  }
  if (ownedItemIDs.size !== expectedItemIDs.size
    || [...expectedItemIDs].some((id) => !ownedItemIDs.has(id))) {
    throw new StoreError("Каждый элемент должен принадлежать доске ровно один раз.");
  }
  validateSpatialElements(value.elements, ownedItemIDs, boardID);
}

function validateBoardHierarchy(
  value: unknown,
  workspace: WorkspaceIndex,
): asserts value is BoardHierarchy {
  if (!isRecord(value) || value.format !== 1
    || typeof value.rootBoardID !== "string" || !Array.isArray(value.boards)) {
    throw new StoreError("Иерархия досок повреждена.");
  }
  assertUUID(value.rootBoardID, "board.rootBoardID");
  if (!sameID(value.rootBoardID, workspace.rootBoardID)) {
    throw new StoreError("Корневая доска не совпадает с workspace.");
  }
  validateStamp(value.stamp, "boardHierarchy.stamp");
  const nodeIDs = new Set<string>();
  const owned = new Set<string>();
  const parentByBoard = new Map<string, string>();
  const boardItems = new Set(
    workspace.items.filter((item) => item.kind === "board")
      .map((item) => item.id.toLowerCase()),
  );
  for (const node of value.boards) {
    if (!isRecord(node) || typeof node.id !== "string" || !isRecord(node.board)
      || !Array.isArray(node.board.freeItems) || !Array.isArray(node.board.stacks)) {
      throw new StoreError("Узел доски повреждён.");
    }
    assertUUID(node.id, "boardNode.id");
    if (node.portalCamera !== undefined) {
      if (!isRecord(node.portalCamera)) {
        throw new StoreError("Камера портала повреждена.");
      }
      validateWorldPoint(node.portalCamera.center, "boardNode.portalCamera.center");
      if (typeof node.portalCamera.scale !== "number"
        || !Number.isFinite(node.portalCamera.scale)
        || node.portalCamera.scale <= 0) {
        throw new StoreError("Масштаб портала поврежден.");
      }
    }
    if (node.portalStamp !== undefined) {
      validateStamp(node.portalStamp, "boardNode.portalStamp");
      if (compareStamp(node.portalStamp as VersionStamp, value.stamp as VersionStamp) > 0) {
        throw new StoreError("Камера портала новее иерархии.");
      }
    }
    const nodeID = node.id.toLowerCase();
    if (nodeIDs.has(nodeID)) throw new StoreError("Повторяется id доски.");
    nodeIDs.add(nodeID);
    const localIDs = new Set<string>();
    for (const placement of node.board.freeItems) {
      if (isRecord(placement) && typeof placement.itemID === "string") {
        localIDs.add(placement.itemID.toLowerCase());
      }
    }
    for (const stack of node.board.stacks) {
      if (isRecord(stack) && Array.isArray(stack.itemIDs)) {
        for (const id of stack.itemIDs) {
          if (typeof id === "string") localIDs.add(id.toLowerCase());
        }
      }
    }
    validateBoardDocument(node.board, localIDs, node.id);
    for (const itemID of localIDs) {
      if (owned.has(itemID)) throw new StoreError("Предмет принадлежит двум доскам.");
      owned.add(itemID);
      if (boardItems.has(itemID)) parentByBoard.set(itemID, nodeID);
    }
  }
  const expected = new Set(workspace.items.map((item) => item.id.toLowerCase()));
  if (owned.size !== expected.size || [...expected].some((id) => !owned.has(id))) {
    throw new StoreError("Каждый элемент должен принадлежать одной доске.");
  }
  const expectedNodes = new Set([...boardItems, workspace.rootBoardID.toLowerCase()]);
  if (nodeIDs.size !== expectedNodes.size
    || [...expectedNodes].some((id) => !nodeIDs.has(id))) {
    throw new StoreError("Порталы и дочерние доски не совпадают.");
  }
  for (const boardID of boardItems) {
    const seen = new Set<string>();
    let cursor = boardID;
    while (!sameID(cursor, workspace.rootBoardID)) {
      if (seen.has(cursor)) throw new StoreError("Доски образуют цикл.");
      seen.add(cursor);
      const parent = parentByBoard.get(cursor);
      if (!parent) throw new StoreError("Вложенная доска недостижима.");
      cursor = parent;
    }
  }
}

function validateSpatialElements(
  elements: unknown[],
  itemIDs: Set<string>,
  boardID: string,
): asserts elements is SpatialElement[] {
  const ids = new Set<string>();
  for (const element of elements) {
    if (!isRecord(element) || typeof element.id !== "string" || !element.id.trim()) {
      throw new StoreError("Пространственный элемент поврежден.");
    }
    if (ids.has(element.id)) throw new StoreError(`Повторяется id элемента: ${element.id}`);
    ids.add(element.id);
    validateSurface(element.surface, "element.surface");
    const surface = element.surface as unknown as SurfaceID;
    if (surface.kind === "page") {
      throw new StoreError("Листовые элементы должны храниться в файле листа.");
    }
    if (surface.kind === "cover" && !itemIDs.has(surface.ownerID!.toLowerCase())) {
      throw new StoreError("Элемент ссылается на неизвестную обложку.");
    }
    if (surface.kind === "board" && !sameID(surface.ownerID, boardID)) {
      throw new StoreError("Элемент принадлежит другой доске.");
    }
    if (!isFrame(element.frame)) throw new StoreError(`frame элемента ${element.id} поврежден.`);
    assertSpatialFrame(element.frame, surface);
    if (surface.kind === "board") {
      validateWorldPoint(element.worldOrigin, `worldOrigin элемента ${element.id}`);
    } else if (element.worldOrigin !== undefined && element.worldOrigin !== null) {
      throw new StoreError("Элемент обложки не должен иметь мировую позицию.");
    }
    if (element.kind !== "nativeText" && element.kind !== "markdown" && element.kind !== "web") {
      throw new StoreError(`Неизвестный вид элемента: ${String(element.kind)}`);
    }
    for (const field of ["source", "html", "css", "javaScript"] as const) {
      if (typeof element[field] !== "string") {
        throw new StoreError(`${field} элемента ${element.id} поврежден.`);
      }
    }
    if (!("state" in element) || !isJSONValue(element.state)) {
      throw new StoreError(`state элемента ${element.id} поврежден.`);
    }
    validateTextStyle(element.textStyle, `textStyle элемента ${element.id}`);
    validateStamp(element.stamp, `stamp элемента ${element.id}`);
  }
}

function validateSpatialInk(value: unknown): asserts value is SpatialInkJournal {
  if (!isRecord(value) || value.format !== 1 || !Array.isArray(value.actions)) {
    throw new StoreError("Пространственные штрихи повреждены.");
  }
  validateStamp(value.stamp, "spatialInk.stamp");
  const actionIDs = new Set<string>();
  for (const action of value.actions) {
    if (!isRecord(action) || typeof action.id !== "string") {
      throw new StoreError("Действие Pencil повреждено.");
    }
    assertUUID(action.id, "spatialInk.action.id");
    if (actionIDs.has(action.id.toLowerCase())) {
      throw new StoreError(`Повторяется действие Pencil: ${action.id}`);
    }
    actionIDs.add(action.id.toLowerCase());
    if (action.tool !== "pen" && action.tool !== "eraser") {
      throw new StoreError("Инструмент пространственного штриха поврежден.");
    }
    validateRGB(action.color, "spatialInk.action.color");
    validateStamp(action.stamp, "spatialInk.action.stamp");
    validateStamp(action.stateStamp, "spatialInk.action.stateStamp");
    if (typeof action.isActive !== "boolean" || !Array.isArray(action.spans)
      || action.spans.length === 0) {
      throw new StoreError("Состояние действия Pencil повреждено.");
    }
    for (const span of action.spans) validateSpatialInkSpan(span);
  }
}

function validateSpatialInkSpan(value: unknown): void {
  if (!isRecord(value)) throw new StoreError("Часть пространственного штриха повреждена.");
  validateSurface(value.surface, "spatialInk.span.surface");
  const surface = value.surface as unknown as { kind: string };
  if (surface.kind === "page" || !Array.isArray(value.samples) || value.samples.length === 0) {
    throw new StoreError("Часть пространственного штриха повреждена.");
  }
  for (const sample of value.samples) {
    if (!isRecord(sample) || !isSpatialPoint(sample.point)) {
      throw new StoreError("Замер Pencil поврежден.");
    }
    if (surface.kind === "board") validateWorldPoint(sample.worldPoint, "sample.worldPoint");
    if (surface.kind === "cover" && sample.worldPoint !== undefined && sample.worldPoint !== null) {
      throw new StoreError("Замер обложки не должен иметь мировую позицию.");
    }
    for (const name of ["timeOffset", "width", "opacity", "force", "azimuth", "altitude"] as const) {
      if (typeof sample[name] !== "number" || !Number.isFinite(sample[name])) {
        throw new StoreError(`sample.${name} поврежден.`);
      }
    }
    const typedSample = sample as Record<
      "timeOffset" | "width" | "opacity" | "force" | "azimuth" | "altitude",
      number
    >;
    if (typedSample.timeOffset < 0 || typedSample.width <= 0 || typedSample.opacity < 0
      || typedSample.opacity > 1 || typedSample.force < 0) {
      throw new StoreError("Диапазон замера Pencil поврежден.");
    }
  }
}

function validatePresence(value: unknown): asserts value is SessionPresence {
  if (!isRecord(value) || value.format !== 4) {
    throw new StoreError("Текущий контекст поврежден.");
  }
  if (value.mode !== "board" && value.mode !== "cover" && value.mode !== "page"
    && value.mode !== "document") {
    throw new StoreError("Режим текущего контекста поврежден.");
  }
  if (typeof value.boardID !== "string") {
    throw new StoreError("Владелец текущей доски повреждён.");
  }
  assertUUID(value.boardID, "presence.boardID");
  if (!isRecord(value.camera)) throw new StoreError("Камера повреждена.");
  validateWorldPoint(value.camera.center, "camera.center");
  if (typeof value.camera.scale !== "number" || !Number.isFinite(value.camera.scale)
    || value.camera.scale < minimumCameraScale
    || value.camera.scale > maximumCameraScale) {
    throw new StoreError("Масштаб камеры поврежден.");
  }
  if (!isSpatialPoint(value.viewport) || value.viewport.x <= 0 || value.viewport.y <= 0) {
    throw new StoreError("Размер области просмотра поврежден.");
  }
  validateOptionalUUID(value.focusedItemID, "focusedItemID");
  if (typeof value.openProgress !== "number" || !Number.isFinite(value.openProgress)
    || value.openProgress < 0 || value.openProgress > 1) {
    throw new StoreError("Прогресс открытия поврежден.");
  }
  if (value.mode !== "board" && typeof value.focusedItemID !== "string") {
    throw new StoreError("Открытый элемент должен указывать своего владельца.");
  }
  if (typeof value.documentPageIndex !== "number"
    || !Number.isSafeInteger(value.documentPageIndex)
    || value.documentPageIndex < 0) {
    throw new StoreError("Номер страницы документа поврежден.");
  }
  if (value.mode !== "cover" && value.mode !== "document"
    && value.documentPageIndex !== 0) {
    throw new StoreError("Номер страницы принадлежит только документу.");
  }
}

function validateCurrentViewReceipt(value: unknown): asserts value is CurrentViewReceipt {
  if (!isRecord(value) || value.format !== 6) {
    throw new StoreError("Квитанция текущего вида повреждена.");
  }
  validateStamp(value.workspaceStamp, "receipt.workspaceStamp");
  if (typeof value.boardRevision !== "string" || !/^[0-9a-f]{64}$/.test(value.boardRevision)) {
    throw new StoreError("Версия дерева в квитанции повреждена.");
  }
  validateStamp(value.spatialInkStamp, "receipt.spatialInkStamp");
  validatePresence(value.presence);
  if (!isSpatialPoint(value.renderViewport)
    || value.renderViewport.x <= 0 || value.renderViewport.y <= 0) {
    throw new StoreError("Размер текущего изображения поврежден.");
  }
  if (typeof value.pngSHA256 !== "string" || !/^[0-9a-f]{64}$/.test(value.pngSHA256)) {
    throw new StoreError("Отпечаток текущего изображения поврежден.");
  }
  validateCurrentViewSurface(value.surface, value.presence);
}

function validateCurrentViewSurface(
  value: unknown,
  presence: SessionPresence,
): void {
  if (!isRecord(value) || typeof value.kind !== "string") {
    throw new StoreError("Поверхность текущего изображения повреждена.");
  }
  if (value.kind !== presence.mode) {
    throw new StoreError("Поверхность не совпадает с текущим режимом.");
  }
  if (value.kind === "board") {
    if (typeof value.boardID !== "string") {
      throw new StoreError("Квитанция доски повреждена.");
    }
    assertUUID(value.boardID, "receipt.surface.boardID");
    if (!sameID(value.boardID, presence.boardID)) {
      throw new StoreError("Квитанция описывает другую вложенную доску.");
    }
    return;
  }
  if (value.kind === "cover") {
    if (typeof value.itemID !== "string") {
      throw new StoreError("Квитанция обложки повреждена.");
    }
    assertUUID(value.itemID, "receipt.surface.itemID");
    if (presence.focusedItemID?.toLowerCase() !== value.itemID.toLowerCase()) {
      throw new StoreError("Квитанция описывает другую обложку.");
    }
    return;
  }
  if (value.kind === "page") {
    if (typeof value.itemID !== "string"
      || !isRecord(value.revision)
      || typeof value.revision.pageID !== "string") {
      throw new StoreError("Квитанция листа повреждена.");
    }
    assertUUID(value.itemID, "receipt.surface.itemID");
    if (presence.focusedItemID?.toLowerCase() !== value.itemID.toLowerCase()) {
      throw new StoreError("Квитанция описывает лист другой тетради.");
    }
    assertUUID(value.revision.pageID, "receipt.surface.revision.pageID");
    validateStamp(value.revision.drawingStamp, "receipt.surface.revision.drawingStamp");
    validateStamp(value.revision.agentStamp, "receipt.surface.revision.agentStamp");
    validateSHA256(value.snapshotPNG_SHA256, "снимка листа");
    return;
  }
  if (value.kind === "document") {
    if (!isRecord(value.revision)
      || typeof value.revision.documentID !== "string") {
      throw new StoreError("Квитанция документа повреждена.");
    }
    assertUUID(value.revision.documentID, "receipt.surface.revision.documentID");
    validateStamp(value.revision.contentStamp, "receipt.surface.revision.contentStamp");
    validateStamp(value.revision.stateStamp, "receipt.surface.revision.stateStamp");
    if (!Number.isSafeInteger(value.pageIndex) || value.pageIndex !== presence.documentPageIndex) {
      throw new StoreError("Квитанция описывает другой лист документа.");
    }
    validateSHA256(value.snapshotPNG_SHA256, "снимка документа");
    return;
  }
  throw new StoreError("Тип поверхности текущего изображения неизвестен.");
}

function validateSHA256(value: unknown, owner: string): void {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new StoreError(`Отпечаток ${owner} поврежден.`);
  }
}

function validateStamp(value: unknown, owner: string): void {
  if (!isRecord(value) || typeof value.actor !== "string") {
    throw new StoreError(`${owner} поврежден.`);
  }
  assertUUID(value.actor, `${owner}.actor`);
  if (
    typeof value.counter !== "number" ||
    !Number.isSafeInteger(value.counter) ||
    value.counter < 0 ||
    value.counter > Number.MAX_SAFE_INTEGER
  ) {
    throw new StoreError(`${owner}.counter поврежден.`);
  }
}

function validateWorldPoint(value: unknown, owner: string): asserts value is WorldPoint {
  if (!isRecord(value)) throw new StoreError(`${owner} поврежден.`);
  for (const name of ["tileX", "tileY"] as const) {
    if (typeof value[name] !== "number" || !Number.isSafeInteger(value[name])) {
      throw new StoreError(`${owner}.${name} поврежден.`);
    }
  }
  for (const name of ["localX", "localY"] as const) {
    if (typeof value[name] !== "number" || !Number.isFinite(value[name])
      || value[name] < 0 || value[name] >= WORLD_TILE_SIZE) {
      throw new StoreError(`${owner}.${name} должен лежать в пределах тайла.`);
    }
  }
}

function validateSurface(value: unknown, owner: string): void {
  if (!isRecord(value)
    || (value.kind !== "board" && value.kind !== "cover" && value.kind !== "page")) {
    throw new StoreError(`${owner} поврежден.`);
  }
  if (typeof value.ownerID !== "string") {
    throw new StoreError(`${owner}.ownerID поврежден.`);
  }
  assertUUID(value.ownerID, `${owner}.ownerID`);
}

function validateTextStyle(value: unknown, owner: string): void {
  if (!isRecord(value)) throw new StoreError(`${owner} поврежден.`);
  for (const name of ["fontSize", "weight", "red", "green", "blue", "alpha"] as const) {
    if (typeof value[name] !== "number" || !Number.isFinite(value[name])) {
      throw new StoreError(`${owner}.${name} поврежден.`);
    }
  }
  const style = value as Record<
    "fontSize" | "weight" | "red" | "green" | "blue" | "alpha",
    number
  >;
  if (style.fontSize < 8 || style.fontSize > 240 || style.weight < 0 || style.weight > 1
    || [style.red, style.green, style.blue, style.alpha].some(
      (component) => component < 0 || component > 1,
    )) {
    throw new StoreError(`${owner} содержит значение вне диапазона.`);
  }
}

function validateRGB(value: unknown, owner: string): void {
  if (!isRecord(value)) throw new StoreError(`${owner} поврежден.`);
  for (const name of ["red", "green", "blue"] as const) {
    if (typeof value[name] !== "number" || !Number.isFinite(value[name])
      || value[name] < 0 || value[name] > 1) {
      throw new StoreError(`${owner}.${name} поврежден.`);
    }
  }
}

function validateZIndex(value: unknown, owner: string): void {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new StoreError(`${owner} поврежден.`);
  }
}

function validateOptionalUUID(value: unknown, owner: string): void {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") throw new StoreError(`${owner} поврежден.`);
  assertUUID(value, owner);
}

function addOwnedItem(ids: Set<string>, value: string): void {
  const normalized = value.toLowerCase();
  if (ids.has(normalized)) {
    throw new StoreError(`Элемент ${value} принадлежит доске больше одного раза.`);
  }
  ids.add(normalized);
}

function isSpatialPoint(value: unknown): value is { x: number; y: number } {
  return isRecord(value)
    && typeof value.x === "number" && Number.isFinite(value.x)
    && typeof value.y === "number" && Number.isFinite(value.y);
}

function sameID(first: string, second: string): boolean {
  return first.toLowerCase() === second.toLowerCase();
}

function compareStamp(first: VersionStamp, second: VersionStamp): number {
  if (first.counter !== second.counter) return first.counter - second.counter;
  return first.actor.toLowerCase().localeCompare(second.actor.toLowerCase());
}

function isFrame(value: unknown): value is PageRect {
  return isRecord(value)
    && typeof value.x === "number"
    && typeof value.y === "number"
    && typeof value.width === "number"
    && typeof value.height === "number";
}

function isPageDimension(value: unknown): value is number {
  return typeof value === "number"
    && Number.isFinite(value)
    && value > 0
    && value <= MAXIMUM_PAGE_DIMENSION;
}

function isCanonicalBase64(value: string): boolean {
  return Buffer.from(value, "base64").toString("base64") === value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isJSONValue(value: unknown): boolean {
  if (value === null || typeof value === "boolean" || typeof value === "string") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJSONValue);
  if (isRecord(value)) return Object.values(value).every(isJSONValue);
  return false;
}

function isEmptyObject(value: unknown): boolean {
  return isRecord(value) && Object.keys(value).length === 0;
}

async function readJSON<T>(path: string, owner: string): Promise<T> {
  try {
    const snapshot = readSnapshot.getStore();
    if (snapshot && path.startsWith(`${snapshot.root}/`)) {
      const value = snapshot.files[path.slice(snapshot.root.length + 1)];
      if (value !== undefined) return structuredClone(value) as T;
      const relative = path.slice(snapshot.root.length + 1);
      if (/^(pages|documents|document-states|collaboration)\//.test(relative) || ["workspace.json", "board.json", "spatial-ink.json", "last-context.json"].includes(relative)) {
        throw new StoreError(`Владелец ${owner} отсутствует в рассмотренном снимке.`);
      }
    }
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch (error) {
    if (isMissing(error)) {
      throw new StoreError(
        `Файл ${owner} еще не создан. Откройте Notebook на Mac.`,
      );
    }
    if (error instanceof SyntaxError) throw new StoreError(`Файл ${owner} поврежден.`);
    throw error;
  }
}

function assertUUID(value: string, owner: string): void {
  if (!UUID_PATTERN.test(value)) throw new StoreError(`${owner} содержит неверный UUID.`);
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException)?.code === "ENOENT";
}
