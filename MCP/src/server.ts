import { readFile } from "node:fs/promises";

import { McpServer } from "@modelcontextprotocol/server";
import { marked } from "marked";
import * as z from "zod/v4";

import type {
  AgentElement,
  JSONValue,
  PageDocument,
} from "./domain.js";
import { publicPage, revision } from "./domain.js";
import { StoreError, TetradStore, assertFrame } from "./store.js";

const frameSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
  width: z.number().positive().finite(),
  height: z.number().positive().finite(),
});

const pageSelection = {
  page_id: z.uuid().optional().describe("UUID страницы; по умолчанию текущая страница."),
};

export function createServer(store = new TetradStore()): McpServer {
  const server = new McpServer({ name: "tetrad", version: "0.1.0" });

  server.registerTool(
    "tetrad_context",
    {
      title: "Current Tetrad context",
      description:
        "Read the selected notebook and page on this Mac. Call this first to locate the page Amir sees.",
      inputSchema: z.object({}),
    },
    () => safely(async () => {
      const { workspace, page } = await store.readSelected();
      const notebookIndex = workspace.notebooks.findIndex(
        (notebook) => notebook.id.toLowerCase() === workspace.selectedNotebookID.toLowerCase(),
      );
      const notebook = workspace.notebooks[notebookIndex];
      if (!notebook) throw new StoreError("Выбранная тетрадь не найдена.");
      const pageIndex = notebook.pageIDs.findIndex(
        (pageID) => pageID.toLowerCase() === page.id.toLowerCase(),
      );
      return {
        notebook: {
          id: notebook.id,
          title: notebook.title,
          number: notebookIndex + 1,
          count: workspace.notebooks.length,
        },
        page: {
          id: page.id,
          number: pageIndex + 1,
          count: notebook.pageIDs.length,
          size: page.size,
          drawingRevision: revision(page.drawingStamp),
          agentRevision: revision(page.agentStamp),
        },
      };
    }),
  );

  server.registerTool(
    "tetrad_read_page",
    {
      title: "Read a Tetrad page",
      description:
        "Read page size and all agent-authored Markdown, SVG, CSS, JavaScript, and interactive state. " +
        "Call tetrad_render_page to see Pencil handwriting.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id }) => safely(async () => {
      const page = page_id
        ? await store.readPage(page_id)
        : (await store.readSelected()).page;
      return publicPage(page);
    }),
  );

  server.registerTool(
    "tetrad_render_page",
    {
      title: "See Pencil handwriting",
      description:
        "Return a PNG of the faint grid and Apple Pencil drawing. " +
        "Agent-authored web layers are returned as source by tetrad_read_page.",
      inputSchema: z.object(pageSelection),
    },
    ({ page_id }) => safely(async () => {
      const page = page_id
        ? await store.readPage(page_id)
        : (await store.readSelected()).page;
      let png: Buffer;
      let renderedRevision: string;
      try {
        [png, renderedRevision] = await Promise.all([
          readFile(store.previewPath(page.id)),
          readFile(store.previewRevisionPath(page.id), "utf8"),
        ]);
      } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === "ENOENT") {
          throw new StoreError(
            "Предпросмотр еще не создан. Откройте «Тетрадь» на Mac и оставьте ее запущенной.",
          );
        }
        throw error;
      }
      const currentRevision = revision(page.drawingStamp);
      if (renderedRevision.trim() !== currentRevision) {
        throw new StoreError(
          "Предпросмотр догоняет новый штрих. Повторите tetrad_render_page через мгновение.",
        );
      }
      return {
        data: {
          pageID: page.id,
          drawingRevision: currentRevision,
          pixelEncoding: "image/png",
        },
        image: png.toString("base64"),
      };
    }, true),
  );

  server.registerTool(
    "tetrad_put_markdown",
    {
      title: "Put Markdown on a Tetrad page",
      description:
        "Create or replace one transparent Markdown layer. The frame is in page points; there is no card, border, or toolbar.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        markdown: z.string(),
        css: z.string().default(""),
      }),
    },
    ({ page_id, expected_revision, id, frame, markdown, css }) => safely(async () => {
      const element: AgentElement = {
        id,
        kind: "markdown",
        frame,
        source: markdown,
        html: await marked.parse(markdown, { async: true, gfm: true }),
        css,
        javaScript: "",
        state: {},
      };
      const page = await store.replaceElements({
        pageID: page_id,
        expectedRevision: expected_revision,
        transform: (elements, currentPage) => {
          assertFrame(frame, currentPage);
          return upsert(elements, element);
        },
      });
      return mutationReceipt(page, element.id);
    }),
  );

  server.registerTool(
    "tetrad_put_web",
    {
      title: "Put an interactive web layer on a Tetrad page",
      description:
        "Create or replace one transparent HTML/SVG/CSS/JavaScript layer. " +
        "Use window.tetrad.state to read state and window.tetrad.commit(value) after a user action. " +
        "The layer has no surrounding UI and cannot use the network.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        id: z.string().trim().min(1).max(120),
        frame: frameSchema,
        html: z.string(),
        css: z.string().default(""),
        javascript: z.string().default(""),
        state: z.json().default({}),
      }),
    },
    ({ page_id, expected_revision, id, frame, html, css, javascript, state }) =>
      safely(async () => {
        assertJavaScript(javascript);
        const element: AgentElement = {
          id,
          kind: "web",
          frame,
          source: html,
          html,
          css,
          javaScript: javascript,
          state: state as JSONValue,
        };
        const page = await store.replaceElements({
          pageID: page_id,
          expectedRevision: expected_revision,
          transform: (elements, currentPage) => {
            assertFrame(frame, currentPage);
            return upsert(elements, element);
          },
        });
        return mutationReceipt(page, element.id);
      }),
  );

  server.registerTool(
    "tetrad_remove_elements",
    {
      title: "Remove layers from a Tetrad page",
      description: "Remove named agent-authored layers while preserving the Pencil drawing.",
      inputSchema: z.object({
        ...pageSelection,
        expected_revision: z.string().min(1).describe("agentRevision from tetrad_read_page."),
        ids: z.array(z.string().trim().min(1)).min(1),
      }),
    },
    ({ page_id, expected_revision, ids }) => safely(async () => {
      const remove = new Set(ids);
      let removed = 0;
      const page = await store.replaceElements({
        pageID: page_id,
        expectedRevision: expected_revision,
        transform: (elements) => elements.filter((element) => {
          if (!remove.has(element.id)) return true;
          removed += 1;
          return false;
        }),
      });
      return {
        pageID: page.id,
        removed,
        agentRevision: revision(page.agentStamp),
      };
    }),
  );

  return server;
}

function upsert(elements: AgentElement[], replacement: AgentElement): AgentElement[] {
  const index = elements.findIndex((element) => element.id === replacement.id);
  if (index < 0) return [...elements, replacement];
  const next = [...elements];
  next[index] = replacement;
  return next;
}

function mutationReceipt(page: PageDocument, elementID: string): object {
  return {
    pageID: page.id,
    elementID,
    agentRevision: revision(page.agentStamp),
  };
}

function assertJavaScript(source: string): void {
  try {
    // This compiles the body only. Execution remains inside WKWebView's local CSP sandbox.
    Function(source);
  } catch (error) {
    throw new StoreError(`JavaScript содержит синтаксическую ошибку: ${(error as Error).message}`);
  }
}

type ToolData = object;

async function safely(
  operation: () => Promise<ToolData | { data: ToolData; image: string }>,
  hasImage = false,
): Promise<{
  content: Array<
    | { type: "text"; text: string }
    | { type: "image"; data: string; mimeType: "image/png" }
  >;
  structuredContent?: object;
  isError?: boolean;
}> {
  try {
    const result = await operation();
    if (hasImage && "image" in result && "data" in result) {
      return {
        content: [
          { type: "text", text: JSON.stringify(result.data, null, 2) },
          { type: "image", data: result.image, mimeType: "image/png" },
        ],
        structuredContent: result.data,
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      structuredContent: result,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: message }],
      isError: true,
    };
  }
}
