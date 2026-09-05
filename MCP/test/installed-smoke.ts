import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import { waitForSettledSnapshot } from "../src/server.js";
import { NotebookStore, StoreError } from "../src/store.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
delete process.env.NOTEBOOK_HOME;
const environment = getDefaultEnvironment();
delete environment.NOTEBOOK_HOME;
const client = new Client({ name: "notebook-installed-proof", version: "0.1.0" });
const transport = new StdioClientTransport({ command: join(root, "run.sh"), env: environment, stderr: "pipe" });
try {
  await client.connect(transport);
  const observed = await waitForSettledSnapshot(async () => {
    const result = await client.callTool({ name: "notebook_observe", arguments: {} });
    const status = result.structuredContent as { code?: string; message?: string; visual?: {status:string} } | undefined;
    if (status?.visual?.status === "pending" || (result.isError && status?.code === "snapshot_pending")) {
      throw new StoreError(status.message ?? "Снимок обновляется.");
    }
    if (result.isError && status?.message === "Квитанция текущего вида повреждена.") {
      // A newly launched publisher replaces the previous installed format.
      throw new StoreError("Квитанция установленного приложения обновляется.");
    }
    assert.notEqual(result.isError, true, JSON.stringify(result.structuredContent ?? result.content));
    return result;
  }, { timeoutMilliseconds: 30_000, pollMilliseconds: 100 });
  assert.ok(observed.content.some((block) => block.type === "image"));
  const receipt = await new NotebookStore().readCurrentViewReceipt();
  console.log(JSON.stringify({
    status: "ready",
    receiptFormat: receipt.format,
    boardRevision: receipt.boardRevision,
    pngSHA256: receipt.pngSHA256,
    presence: receipt.presence,
    observation: observed.structuredContent,
  }, null, 2));
} finally {
  await client.close();
}
