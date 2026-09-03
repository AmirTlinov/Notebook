import assert from "node:assert/strict";
import test from "node:test";

import { waitForSettledSnapshot } from "../src/server.js";
import { StoreError } from "../src/store.js";

test("one observation waits for an in-flight snapshot", async () => {
  let attempts = 0;
  const result = await waitForSettledSnapshot(async () => {
    attempts += 1;
    if (attempts < 3) {
      throw new StoreError("Снимок текущего вида еще собирается в фоне.");
    }
    return "ready";
  }, {
    timeoutMilliseconds: 100,
    pollMilliseconds: 1,
  });

  assert.equal(result, "ready");
  assert.equal(attempts, 3);
});

test("observation returns the pending cause after its bounded wait", async () => {
  const startedAt = Date.now();
  await assert.rejects(
    waitForSettledSnapshot(async () => {
      throw new StoreError("Снимок текущего вида еще собирается в фоне.");
    }, {
      timeoutMilliseconds: 20,
      pollMilliseconds: 2,
    }),
    /собирается/,
  );
  assert.ok(Date.now() - startedAt >= 15);
});
