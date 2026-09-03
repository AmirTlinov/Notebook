import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import {
  StdioClientTransport,
  getDefaultEnvironment,
} from "@modelcontextprotocol/client/stdio";

import { appActor, itemID, pageID, writeFixture } from "./fixture.js";

const here = dirname(fileURLToPath(import.meta.url));
const mcpRoot = join(here, "..");
const storeRoot = await mkdtemp(join(tmpdir(), "notebook-mcp-smoke-"));

try {
  await writeFixture(storeRoot);
  const client = new Client({ name: "notebook-smoke", version: "0.1.0" });
  const transport = new StdioClientTransport({
    command: join(mcpRoot, "run.sh"),
    env: { ...getDefaultEnvironment(), NOTEBOOK_HOME: storeRoot },
    stderr: "pipe",
  });
  await client.connect(transport);

  const listed = await client.listTools();
  assert.deepEqual(
    listed.tools.map((tool) => tool.name).sort(),
    [
      "notebook_context",
      "notebook_create_document",
      "notebook_create_notebook",
      "notebook_export_document",
      "notebook_move_nodes",
      "notebook_page_map",
      "notebook_patch_document",
      "notebook_put_markdown",
      "notebook_put_spatial_markdown",
      "notebook_put_spatial_web",
      "notebook_put_web",
      "notebook_read_board",
      "notebook_read_document",
      "notebook_read_notebook",
      "notebook_read_page",
      "notebook_remove_elements",
      "notebook_remove_spatial_elements",
      "notebook_rename_item",
      "notebook_render_page",
      "notebook_render_region",
      "notebook_render_regions",
      "notebook_render_view",
      "notebook_stack_nodes",
    ],
  );

  const context = await client.callTool({ name: "notebook_context", arguments: {} });
  assert.equal(context.isError, undefined);
  assert.match(JSON.stringify(context.structuredContent), /Notebook 1/);
  assert.match(JSON.stringify(context.structuredContent), /shortID/);
  assert.match(JSON.stringify(context.structuredContent), /screenFrame/);
  assert.equal(
    (context.structuredContent as { workspaceRevision: string })
      .workspaceRevision,
    `0@${appActor}`,
  );
  assert.equal(
    (context.structuredContent as { documentPageIndex: number })
      .documentPageIndex,
    0,
  );

  const currentView = await client.callTool({
    name: "notebook_render_view",
    arguments: {},
  });
  assert.equal(currentView.isError, undefined);
  assert.ok(currentView.content.some((block) => block.type === "image"));
  assert.equal(
    (currentView.structuredContent as { documentPageIndex: number })
      .documentPageIndex,
    0,
  );

  const currentViewPath = join(storeRoot, "previews", "current-view.png");
  const currentViewPNG = await readFile(currentViewPath);
  await writeFile(currentViewPath, Buffer.from("updating"));
  const mismatchedCurrentView = await client.callTool({
    name: "notebook_render_view",
    arguments: {},
  });
  assert.equal(mismatchedCurrentView.isError, true);
  assert.match(JSON.stringify(mismatchedCurrentView.content), /квитанция обновляются/);
  await writeFile(currentViewPath, currentViewPNG);

  const spatialChanged = await client.callTool({
    name: "notebook_put_spatial_markdown",
    arguments: {
      expected_revision: `0@${appActor}`,
      surface: { kind: "cover", item_id: itemID },
      id: "cover-note",
      frame: { x: 80, y: 360, width: 420, height: 180 },
      markdown: "# На обложке",
    },
  });
  assert.equal(spatialChanged.isError, undefined);
  assert.match(JSON.stringify(spatialChanged.structuredContent), /cover-note/);
  const spatialRevision = (
    spatialChanged.structuredContent as { boardRevision: string }
  ).boardRevision;

  const changed = await client.callTool({
    name: "notebook_put_markdown",
    arguments: {
      expected_revision: `0@${appActor}`,
      id: "mcp-smoke",
      frame: { x: 52, y: 52, width: 300, height: 180 },
      markdown: "# MCP работает",
    },
  });
  assert.equal(changed.isError, undefined);
  assert.match(JSON.stringify(changed.structuredContent), /mcp-smoke/);

  const rendered = await client.callTool({
    name: "notebook_render_page",
    arguments: {},
  });
  assert.equal(rendered.isError, undefined);
  assert.ok(rendered.content.some((block) => block.type === "image"));

  const pageMap = await client.callTool({
    name: "notebook_page_map",
    arguments: {},
  });
  assert.equal(pageMap.isError, undefined);
  const map = pageMap.structuredContent as {
    drawingRevision: string;
    regions: Array<{ id: string }>;
  };
  assert.equal(map.regions[0]?.id, "r00-00-01-01");

  const unchangedMap = await client.callTool({
    name: "notebook_page_map",
    arguments: { since_drawing_revision: map.drawingRevision },
  });
  assert.equal(unchangedMap.isError, undefined);
  assert.deepEqual(
    (unchangedMap.structuredContent as {
      delta: { available: boolean; changedRegionIDs: string[]; unchangedRegionIDs: string[] };
    }).delta,
    {
      fromDrawingRevision: map.drawingRevision,
      available: true,
      changedRegionIDs: [],
      removedRegionIDs: [],
      unchangedRegionIDs: ["r00-00-01-01"],
    },
  );

  const region = await client.callTool({
    name: "notebook_render_region",
    arguments: {
      expected_drawing_revision: map.drawingRevision,
      region_id: "r00-00-01-01",
      mode: "ink",
    },
  });
  assert.equal(region.isError, undefined);
  assert.equal(region.content.filter((block) => block.type === "image").length, 1);

  const regions = await client.callTool({
    name: "notebook_render_regions",
    arguments: {
      expected_drawing_revision: map.drawingRevision,
      region_ids: ["r00-00-01-01"],
    },
  });
  assert.equal(regions.isError, undefined);
  assert.equal(regions.content.filter((block) => block.type === "image").length, 1);

  const regionPath = join(
    storeRoot,
    "previews",
    `${pageID}.regions`,
    "r00-00-01-01.faithful.png",
  );
  const regionPNG = await readFile(regionPath);
  await writeFile(regionPath, Buffer.from("updating"));
  const mismatchedRegion = await client.callTool({
    name: "notebook_render_region",
    arguments: {
      expected_drawing_revision: map.drawingRevision,
      region_id: "r00-00-01-01",
    },
  });
  assert.equal(mismatchedRegion.isError, true);
  assert.match(JSON.stringify(mismatchedRegion.content), /квитанция обновляются/);
  await writeFile(regionPath, regionPNG);

  const pagePath = join(storeRoot, "pages", `${pageID}.json`);
  const page = JSON.parse(await readFile(pagePath, "utf8")) as {
    drawingStamp: { counter: number };
  };
  page.drawingStamp.counter += 1;
  await writeFile(pagePath, JSON.stringify(page));
  const stalePreview = await client.callTool({
    name: "notebook_render_page",
    arguments: {},
  });
  assert.equal(stalePreview.isError, true);
  assert.match(
    JSON.stringify(stalePreview.content),
    /не означает, что Амир сейчас рисует/,
  );

  const createdDocument = await client.callTool({
    name: "notebook_create_document",
    arguments: {
      expected_workspace_revision: `0@${appActor}`,
      expected_board_revision: spatialRevision,
      title: "MCP Document",
      paper_size: "letter",
      center: { tileX: 0, tileY: 0, localX: 600, localY: 700 },
      blocks: [
        { id: "body", kind: "markdown", source: "# Документ\n\nФормула $x_1$." },
        { id: "math", kind: "latex", source: "E=mc^2" },
        {
          id: "counter",
          kind: "interactive",
          html: "<button id='counter'>0</button>",
          javascript: "document.querySelector('#counter').onclick = () => notebook.commit({ count: (notebook.state.count || 0) + 1 });",
          initial_state: { count: 0 },
          height: 160,
        },
      ],
    },
  });
  assert.equal(createdDocument.isError, undefined);
  const createdReceipt = createdDocument.structuredContent as {
    documentID: string;
    contentRevision: string;
    paperSize: string;
  };
  assert.equal(createdReceipt.paperSize, "letter");

  const readDocument = await client.callTool({
    name: "notebook_read_document",
    arguments: { document_id: createdReceipt.documentID },
  });
  assert.equal(readDocument.isError, undefined);
  assert.match(JSON.stringify(readDocument.structuredContent), /counter/);
  assert.equal(
    (readDocument.structuredContent as { paperSize: string }).paperSize,
    "letter",
  );

  const patchedDocument = await client.callTool({
    name: "notebook_patch_document",
    arguments: {
      document_id: createdReceipt.documentID,
      expected_revision: createdReceipt.contentRevision,
      preamble: "\\usepackage{microtype}",
      blocks: [
        { id: "body", kind: "markdown", source: "# Готовый документ" },
        { id: "math", kind: "latex", source: "\\[E=mc^2\\]" },
      ],
    },
  });
  assert.equal(patchedDocument.isError, undefined);
  assert.match(JSON.stringify(patchedDocument.structuredContent), /Готовый документ/);

  const exportedDocument = await client.callTool({
    name: "notebook_export_document",
    arguments: { document_id: createdReceipt.documentID },
  });
  assert.equal(exportedDocument.isError, undefined);
  assert.match(JSON.stringify(exportedDocument.structuredContent), /pdfSHA256/);

  await client.close();
  process.stdout.write(
    "MCP smoke passed: page map, region batches, notebook and document mutation, PDF export, and stale-image rejection work.\n",
  );
} finally {
  await rm(storeRoot, { recursive: true, force: true });
}
