import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { publicAction, type ActionReceipt } from "../src/actions.js";
import { NotebookStore } from "../src/store.js";

test("publication compares revision values, not independent JSON encoder key order", async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-publication-"));
  const socketPath = join(root, "bridge.sock");
  const target = { kind: "board" as const, id: randomUUID() };
  const revision = { target, revision: "5@human", inkRevision: "73@agent" };
  const receipt: ActionReceipt = { id: randomUUID(), createdAt: 1, changes: [], revisions: [revision],
    action: { summary: "Объяснение на доске", references: [], operations: [] } };
  const device = { id: receipt.id, revisions: [{ inkRevision: revision.inkRevision,
    revision: revision.revision, target: { id: target.id, kind: target.kind } }],
    displayComplete: true, shown: [revision], visibleRegions: [{ id: randomUUID() }] };
  const server = createServer({ allowHalfOpen: true }, socket => {
    const chunks: Buffer[] = [];
    socket.on("data", chunk => chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk));
    socket.on("end", () => {
      const packet = JSON.parse(Buffer.concat(chunks).subarray(4).toString());
      const result = packet.request.command === "read" ? { cursor: "1", values: [[]] }
        : packet.request.command === "delivery" ? [device] : [];
      const body = Buffer.from(JSON.stringify({ version: 1, id: packet.id, result }));
      const size = Buffer.alloc(4); size.writeUInt32BE(body.length);
      socket.end(Buffer.concat([size, body]));
    });
  });
  try {
    await chmod(root, 0o700);
    await new Promise<void>(resolve => server.listen(socketPath, resolve));
    await chmod(socketPath, 0o600);
    const store = new NotebookStore(socketPath);
    const saved = await publicAction(receipt, store) as any;
    assert.equal(saved.publication.receivedByIPad.status, "confirmed");
    assert.equal(saved.publication.shownOnIPad.status, "confirmed");
    assert.deepEqual(saved.publication.shownOnIPad.visibleRegions, device.visibleRegions);
    device.revisions[0]!.inkRevision = "74@human";
    const changed = await publicAction(receipt, store) as any;
    assert.equal(changed.publication.receivedByIPad.status, "awaiting_device");
    assert.equal(changed.publication.shownOnIPad.status, "awaiting_display");
    assert.deepEqual(changed.publication.shownOnIPad.visibleRegions, []);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  }
});
