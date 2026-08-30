import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import type {
  AgentElement,
  PageDocument,
  PageRect,
  WorkspaceIndex,
} from "./domain.js";
import { revision } from "./domain.js";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAXIMUM_PAGE_DIMENSION = 2_048;

export class StoreError extends Error {}
export class ConflictError extends StoreError {}

export class TetradStore {
  readonly root: string;
  private mutationTail: Promise<unknown> = Promise.resolve();

  constructor(root = defaultStoreRoot()) {
    this.root = root;
  }

  get indexPath(): string {
    return join(this.root, "workspace.json");
  }

  get pagesPath(): string {
    return join(this.root, "pages");
  }

  pagePath(pageID: string): string {
    assertUUID(pageID, "page_id");
    return join(this.pagesPath, `${pageID.toLowerCase()}.json`);
  }

  previewPath(pageID: string): string {
    assertUUID(pageID, "page_id");
    return join(this.root, "previews", `${pageID.toLowerCase()}.png`);
  }

  previewRevisionPath(pageID: string): string {
    assertUUID(pageID, "page_id");
    return join(this.root, "previews", `${pageID.toLowerCase()}.revision`);
  }

  async readWorkspace(): Promise<WorkspaceIndex> {
    const workspace = await readJSON<unknown>(this.indexPath, "workspace");
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

  async readSelected(): Promise<{
    workspace: WorkspaceIndex;
    page: PageDocument;
  }> {
    const workspace = await this.readWorkspace();
    return {
      workspace,
      page: await this.readPage(workspace.selectedPageID),
    };
  }

  async readActorID(): Promise<string> {
    const actorPath = join(this.root, "mcp-actor.txt");
    try {
      const value = (await readFile(actorPath, "utf8")).trim();
      assertUUID(value, "stored MCP actor");
      return value;
    } catch (error) {
      if (!isMissing(error)) throw error;
    }
    await mkdir(this.root, { recursive: true });
    const actor = randomUUID();
    try {
      const file = await open(actorPath, "wx", 0o600);
      try {
        await file.writeFile(`${actor}\n`, "utf8");
      } finally {
        await file.close();
      }
      return actor;
    } catch (error) {
      if (!isExists(error)) throw error;
      const value = (await readFile(actorPath, "utf8")).trim();
      assertUUID(value, "stored MCP actor");
      return value;
    }
  }

  async replaceElements(args: {
    pageID: string | undefined;
    expectedRevision: string;
    transform: (current: AgentElement[], page: PageDocument) => AgentElement[];
  }): Promise<PageDocument> {
    return this.serializeMutation(() => this.withMutationLock(async () => {
      const page = args.pageID
        ? await this.readPage(args.pageID)
        : (await this.readSelected()).page;
      const currentRevision = revision(page.agentStamp);
      if (args.expectedRevision !== currentRevision) {
        throw new ConflictError(
          `Страница изменилась: ожидалась версия ${args.expectedRevision}, ` +
            `сейчас ${currentRevision}. Сначала снова вызовите tetrad_read_page.`,
        );
      }
      const elements = args.transform(page.elements, page);
      validateElements(elements, page);
      if (JSON.stringify(elements) === JSON.stringify(page.elements)) return page;
      if (page.agentStamp.counter === Number.MAX_SAFE_INTEGER) {
        throw new StoreError("Счётчик версии страницы исчерпан.");
      }
      const actor = await this.readActorID();
      const next: PageDocument = {
        ...page,
        elements,
        agentStamp: { counter: page.agentStamp.counter + 1, actor },
      };
      await atomicJSON(this.pagePath(page.id), next);
      return next;
    }));
  }

  private serializeMutation<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.mutationTail.then(operation, operation);
    this.mutationTail = result.catch(() => undefined);
    return result;
  }

  private async withMutationLock<T>(operation: () => Promise<T>): Promise<T> {
    await mkdir(this.root, { recursive: true });
    const lockPath = join(this.root, ".mutation-lock");
    let acquired = false;
    for (let attempt = 0; attempt < 200; attempt += 1) {
      try {
        await mkdir(lockPath);
        acquired = true;
        break;
      } catch (error) {
        if (!isExists(error)) throw error;
        try {
          const lock = await stat(lockPath);
          if (Date.now() - lock.mtimeMs > 15_000) {
            await rm(lockPath, { recursive: true, force: true });
            continue;
          }
        } catch (inspectionError) {
          if (!isMissing(inspectionError)) throw inspectionError;
        }
        await new Promise((resolve) => setTimeout(resolve, 3));
      }
    }
    if (!acquired) throw new StoreError("Хранилище страницы занято дольше 600 мс.");
    try {
      return await operation();
    } finally {
      await rm(lockPath, { recursive: true, force: true });
    }
  }
}

function defaultStoreRoot(): string {
  return process.env.TETRAD_HOME ??
    join(homedir(), "Library", "Application Support", "Tetrad");
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

function validateWorkspace(value: unknown): asserts value is WorkspaceIndex {
  if (!isRecord(value)) throw new StoreError("workspace поврежден.");
  if (value.format !== 1) {
    throw new StoreError(`Неизвестный формат workspace: ${String(value.format)}`);
  }
  if (!Array.isArray(value.notebooks) || value.notebooks.length === 0) {
    throw new StoreError("В workspace нет тетрадей.");
  }
  if (typeof value.selectedNotebookID !== "string" || typeof value.selectedPageID !== "string") {
    throw new StoreError("Выбор workspace поврежден.");
  }
  const selectedNotebookID = value.selectedNotebookID;
  const selectedPageID = value.selectedPageID;
  assertUUID(selectedNotebookID, "selectedNotebookID");
  assertUUID(selectedPageID, "selectedPageID");
  validateStamp(value.stamp, "workspace.stamp");

  const notebookIDs = new Set<string>();
  const pageIDs = new Set<string>();
  let selectedPageBelongsToSelection = false;
  for (const notebook of value.notebooks) {
    if (!isRecord(notebook) || typeof notebook.id !== "string") {
      throw new StoreError("Тетрадь в workspace повреждена.");
    }
    assertUUID(notebook.id, "notebook.id");
    const notebookID = notebook.id.toLowerCase();
    if (notebookIDs.has(notebookID)) throw new StoreError(`Повторяется notebook.id: ${notebook.id}`);
    notebookIDs.add(notebookID);
    if (typeof notebook.title !== "string" || !notebook.title.trim()) {
      throw new StoreError(`Название тетради ${notebook.id} повреждено.`);
    }
    if (!Array.isArray(notebook.pageIDs) || notebook.pageIDs.length === 0) {
      throw new StoreError(`В тетради ${notebook.id} нет листов.`);
    }
    for (const pageID of notebook.pageIDs) {
      if (typeof pageID !== "string") throw new StoreError("pageID поврежден.");
      assertUUID(pageID, "pageID");
      const normalized = pageID.toLowerCase();
      if (pageIDs.has(normalized)) throw new StoreError(`Повторяется pageID: ${pageID}`);
      pageIDs.add(normalized);
    }
    if (notebookID === selectedNotebookID.toLowerCase()) {
      selectedPageBelongsToSelection = notebook.pageIDs.some(
        (pageID) => pageID.toLowerCase() === selectedPageID.toLowerCase(),
      );
    }
  }
  if (!selectedPageBelongsToSelection) {
    throw new StoreError("Выбранный лист не принадлежит выбранной тетради.");
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

async function readJSON<T>(path: string, owner: string): Promise<T> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch (error) {
    if (isMissing(error)) {
      throw new StoreError(
        `Файл ${owner} еще не создан. Откройте приложение «Тетрадь» на Mac.`,
      );
    }
    if (error instanceof SyntaxError) throw new StoreError(`Файл ${owner} поврежден.`);
    throw error;
  }
}

async function atomicJSON(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

function assertUUID(value: string, owner: string): void {
  if (!UUID_PATTERN.test(value)) throw new StoreError(`${owner} содержит неверный UUID.`);
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException)?.code === "ENOENT";
}

function isExists(error: unknown): boolean {
  return (error as NodeJS.ErrnoException)?.code === "EEXIST";
}
