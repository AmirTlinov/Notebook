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
    return readJSON<WorkspaceIndex>(this.indexPath, "workspace");
  }

  async readPage(pageID: string): Promise<PageDocument> {
    const page = await readJSON<PageDocument>(this.pagePath(pageID), "page");
    validatePage(page);
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
      await file.writeFile(`${actor}\n`, "utf8");
      await file.close();
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
        const selected = await this.readSelected();
        const pageID = args.pageID ?? selected.page.id;
        const page = pageID.toLowerCase() === selected.page.id.toLowerCase()
          ? selected.page
          : await this.readPage(pageID);
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

export function defaultStoreRoot(): string {
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

function validateElements(elements: AgentElement[], page: PageDocument): void {
  const ids = new Set<string>();
  for (const element of elements) {
    if (!element.id.trim()) throw new StoreError("id элемента должен быть непустым.");
    if (ids.has(element.id)) throw new StoreError(`Повторяется id элемента: ${element.id}`);
    ids.add(element.id);
    assertFrame(element.frame, page);
    if (element.kind !== "markdown" && element.kind !== "web") {
      throw new StoreError(`Неизвестный вид элемента: ${String(element.kind)}`);
    }
  }
}

function validatePage(page: PageDocument): void {
  if (page.format !== 1) throw new StoreError(`Неизвестный формат страницы: ${page.format}`);
  assertUUID(page.id, "page.id");
  if (!Number.isFinite(page.size.width) || !Number.isFinite(page.size.height)) {
    throw new StoreError("Размер страницы поврежден.");
  }
  if (!Array.isArray(page.elements)) throw new StoreError("Список элементов поврежден.");
  validateElements(page.elements, page);
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
