import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { PageDocument, WorkspaceIndex } from "../src/domain.js";

export const notebookID = "7e7a0000-0000-4000-8000-000000000001";
export const pageID = "7e7a0000-0000-4000-8000-000000000002";
export const appActor = "7e7a0000-0000-4000-8000-000000000003";

export async function writeFixture(root: string): Promise<void> {
  const workspace: WorkspaceIndex = {
    format: 1,
    notebooks: [{ id: notebookID, title: "Тетрадь 1", pageIDs: [pageID] }],
    selectedNotebookID: notebookID,
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
  await mkdir(join(root, "pages"), { recursive: true });
  await mkdir(join(root, "previews"), { recursive: true });
  await writeFile(join(root, "workspace.json"), JSON.stringify(workspace));
  await writeFile(join(root, "pages", `${pageID}.json`), JSON.stringify(page));
  // A minimal valid PNG is sufficient for MCP content-path verification.
  await writeFile(
    join(root, "previews", `${pageID}.png`),
    Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nH0AAAAASUVORK5CYII=", "base64"),
  );
  await writeFile(
    join(root, "previews", `${pageID}.revision`),
    `0@${appActor}\n`,
  );
}
