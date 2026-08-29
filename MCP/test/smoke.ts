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

import { appActor, pageID, writeFixture } from "./fixture.js";

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
      "tetrad_put_markdown",
      "tetrad_put_web",
      "tetrad_read_page",
      "tetrad_remove_elements",
      "tetrad_render_page",
    ],
  );

  const context = await client.callTool({ name: "tetrad_context", arguments: {} });
  assert.equal(context.isError, undefined);
  assert.match(JSON.stringify(context.structuredContent), /Тетрадь 1/);

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
