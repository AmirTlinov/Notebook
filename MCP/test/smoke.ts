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

import { appActor, notebookID, pageID, writeFixture } from "./fixture.js";

const here = dirname(fileURLToPath(import.meta.url));
const mcpRoot = join(here, "..");
const storeRoot = await mkdtemp(join(tmpdir(), "tetrad-mcp-smoke-"));

try {
  await writeFixture(storeRoot);
  const client = new Client({ name: "tetrad-smoke", version: "0.1.0" });
  const transport = new StdioClientTransport({
    command: join(mcpRoot, "run.sh"),
    env: { ...getDefaultEnvironment(), TETRAD_HOME: storeRoot },
    stderr: "pipe",
  });
  await client.connect(transport);

  const listed = await client.listTools();
  assert.deepEqual(
    listed.tools.map((tool) => tool.name).sort(),
    [
      "tetrad_context",
      "tetrad_create_notebook",
      "tetrad_move_nodes",
      "tetrad_put_markdown",
      "tetrad_put_spatial_markdown",
      "tetrad_put_spatial_web",
      "tetrad_put_web",
      "tetrad_read_board",
      "tetrad_read_notebook",
      "tetrad_read_page",
      "tetrad_remove_elements",
      "tetrad_remove_spatial_elements",
      "tetrad_rename_notebook",
      "tetrad_render_page",
      "tetrad_render_view",
      "tetrad_stack_nodes",
    ],
  );

  const context = await client.callTool({ name: "tetrad_context", arguments: {} });
  assert.equal(context.isError, undefined);
  assert.match(JSON.stringify(context.structuredContent), /Тетрадь 1/);

  const currentView = await client.callTool({
    name: "tetrad_render_view",
    arguments: {},
  });
  assert.equal(currentView.isError, undefined);
  assert.ok(currentView.content.some((block) => block.type === "image"));

  const currentViewPath = join(storeRoot, "previews", "current-view.png");
  const currentViewPNG = await readFile(currentViewPath);
  await writeFile(currentViewPath, Buffer.from("updating"));
  const mismatchedCurrentView = await client.callTool({
    name: "tetrad_render_view",
    arguments: {},
  });
  assert.equal(mismatchedCurrentView.isError, true);
  assert.match(JSON.stringify(mismatchedCurrentView.content), /квитанция обновляются/);
  await writeFile(currentViewPath, currentViewPNG);

  const spatialChanged = await client.callTool({
    name: "tetrad_put_spatial_markdown",
    arguments: {
      expected_revision: `0@${appActor}`,
      surface: { kind: "cover", notebook_id: notebookID },
      id: "cover-note",
      frame: { x: 80, y: 360, width: 420, height: 180 },
      markdown: "# На обложке",
    },
  });
  assert.equal(spatialChanged.isError, undefined);
  assert.match(JSON.stringify(spatialChanged.structuredContent), /cover-note/);

  const changed = await client.callTool({
    name: "tetrad_put_markdown",
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
    name: "tetrad_render_page",
    arguments: {},
  });
  assert.equal(rendered.isError, undefined);
  assert.ok(rendered.content.some((block) => block.type === "image"));

  const pagePath = join(storeRoot, "pages", `${pageID}.json`);
  const page = JSON.parse(await readFile(pagePath, "utf8")) as {
    drawingStamp: { counter: number };
  };
  page.drawingStamp.counter += 1;
  await writeFile(pagePath, JSON.stringify(page));
  const stalePreview = await client.callTool({
    name: "tetrad_render_page",
    arguments: {},
  });
  assert.equal(stalePreview.isError, true);
  assert.match(JSON.stringify(stalePreview.content), /догоняет новый штрих/);

  await client.close();
  process.stdout.write(
    "MCP smoke passed: list, read, mutate, fresh image, and stale-image rejection work.\n",
  );
} finally {
  await rm(storeRoot, { recursive: true, force: true });
}
