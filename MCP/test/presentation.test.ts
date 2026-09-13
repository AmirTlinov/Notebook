import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/client/stdio";
import test from "node:test";
import { presentationSchema } from "../src/presentation.js";

const point = { tileX: 0, tileY: 0, localX: 0, localY: 0 };
const view = { deviceID: randomUUID(), sessionID: randomUUID(), sequence: 3, nonce: randomUUID() };
test("presentation distinguishes read, one bounded script and addressed cancellation", () => {
  assert.ok(presentationSchema.safeParse({}).success);
  const id = randomUUID();
  assert.ok(presentationSchema.safeParse({ presentation_id: id, cancel: true }).success);
  assert.ok(presentationSchema.safeParse({ presentation_id: id, view, steps: [
    { focus: { origin: point, width: 100, height: 80 } },
    { svg: '<svg viewBox="0 0 100 80"><circle cx="50" cy="40" r="30"/></svg>', bounds: { origin: point, width: 100, height: 80 } },
  ] }).success);
  for (const input of [{ cancel: true }, { view }, { steps: [{ camera: { center: point, scale: 1 } }] },
    { presentation_id: id, view, steps: [{ svg: "<svg/>" }] },
    { presentation_id: id, view, steps: [{ camera: { center: point, scale: 1 }, focus: { origin: point, width: 100, height: 100 } }] },
    { presentation_id: id, view, steps: Array.from({ length: 7 }, () => ({ duration: 10, camera: { center: point, scale: 1 } })) }]) {
    assert.equal(presentationSchema.safeParse(input).success, false, JSON.stringify(input));
  }
});

test("real stdio tool preserves the presentation ID through the Mac IPC and validates receipts", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-present-")), path = join(root, "bridge.sock");
  const requests: Record<string, any>[] = [];
  const server = createServer({ allowHalfOpen: true }, socket => {
    const chunks: Buffer[] = [];
    socket.on("data", chunk => chunks.push(Buffer.from(chunk)));
    socket.on("end", () => {
      const packet = JSON.parse(Buffer.concat(chunks).subarray(4).toString());
      requests.push(packet.request);
      const result = packet.request.presentation ? { id: packet.request.presentation.id, status: "sent", step: 0 }
        : packet.request.actionID ? { id: packet.request.actionID, status: "completed", step: 0 }
        : { status: "ready", view };
      const body = Buffer.from(JSON.stringify({ version: 1, id: packet.id, result }));
      const size = Buffer.alloc(4); size.writeUInt32BE(body.length);
      socket.end(Buffer.concat([size, body]));
    });
  });
  const client = new Client({ name: "presentation-proof", version: "1" });
  try {
    await chmod(root, 0o700);
    await new Promise<void>(resolve => server.listen(path, resolve)); await chmod(path, 0o600);
    await client.connect(new StdioClientTransport({ command: join(dirname(fileURLToPath(import.meta.url)), "../run.sh"),
      env: { ...getDefaultEnvironment(), NOTEBOOK_SOCKET: path }, stderr: "pipe" }));
    const call = async (args: Record<string, unknown>) => {
      const result = await client.callTool({ name: "notebook_present", arguments: args });
      assert.notEqual(result.isError, true, JSON.stringify(result));
      return result.structuredContent as any;
    };
    assert.deepEqual((await call({})).view, view);
    const id = randomUUID();
    assert.equal((await call({ presentation_id: id, view, steps: [{ camera: { center: point, scale: 1 } }] })).status, "sent");
    assert.equal((await call({ presentation_id: id })).status, "completed");
    assert.equal(requests[1]?.presentation.id, id);
    assert.deepEqual(requests[1]?.presentation.view, view);
    assert.ok(requests.every(request => request.command === "presentation" && !request.action));
  } finally {
    await client.close(); await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  }
});
