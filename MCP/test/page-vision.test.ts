import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  readFreshPageVision,
  readVerifiedPageOverview,
} from "../src/page-vision.js";
import { NotebookStore, StoreError } from "../src/store.js";
import { pageID, writeFixture } from "./fixture.js";

async function withFixture(
  body: (store: NotebookStore, root: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "notebook-vision-"));
  try {
    await writeFixture(root);
    await body(new NotebookStore(root), root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("reads a fresh visible-pixel map for the exact page revision", async () => {
  await withFixture(async (store) => {
    const page = await store.readPage(pageID);
    const receipt = await readFreshPageVision(
      store,
      page,
      `0@${page.drawingStamp.actor}`,
    );

    assert.equal(receipt.pageID, pageID);
    assert.deepEqual(receipt.occupiedCells, [{ column: 0, row: 0 }]);
    assert.equal(receipt.regions[0]?.id, "r00-00-01-01");
    assert.equal(
      (await readVerifiedPageOverview(store, receipt, "faithful")).length > 0,
      true,
    );
  });
});

test("rejects a receipt from the previous drawing revision", async () => {
  await withFixture(async (store, root) => {
    const pagePath = join(root, "pages", `${pageID}.json`);
    const page = JSON.parse(await readFile(pagePath, "utf8")) as {
      drawingStamp: { counter: number };
    };
    page.drawingStamp.counter += 1;
    await writeFile(pagePath, JSON.stringify(page));

    await assert.rejects(
      readFreshPageVision(store, await store.readPage(pageID)),
      (error: unknown) =>
        error instanceof StoreError &&
        /не означает, что Амир сейчас рисует/.test(error.message),
    );
  });
});

test("rejects page pixels that do not match the receipt hash", async () => {
  await withFixture(async (store, root) => {
    const page = await store.readPage(pageID);
    const receipt = await readFreshPageVision(store, page);
    await writeFile(
      join(root, "previews", `${pageID}.png`),
      Buffer.from("mixed revision"),
    );

    await assert.rejects(
      readVerifiedPageOverview(store, receipt, "faithful"),
      (error: unknown) =>
        error instanceof StoreError &&
        /Карта указанного листа собирается/.test(error.message),
    );
  });
});

test("a cold offscreen map requests one explicit page and reuses its identity", async () => {
  await withFixture(async (store, root) => {
    const page = await store.readPage(pageID);
    await rm(join(root, "previews", `${pageID}.vision.json`));
    let requestID: string | undefined;
    const pending = (error: unknown) => {
      assert.ok(error instanceof StoreError && "requestID" in error);
      assert.equal(typeof error.requestID, "string");
      if (requestID) assert.equal(error.requestID, requestID);
      else requestID = error.requestID as string;
      return true;
    };
    await assert.rejects(readFreshPageVision(store, page), pending);
    // Migration has finished. This subsequent addressed read must not decode an unrelated owner.
    await writeFile(join(root, "pages", "7e7a0000-0000-4000-8000-000000000099.json"), "broken unrelated page");
    await assert.rejects(readFreshPageVision(store, page), pending);
    const directory = join(root, "collaboration", "render-requests");
    const files = await readdir(directory);
    assert.equal(files.length, 1);
    const request = JSON.parse(await readFile(join(directory, files[0]!), "utf8"));
    assert.equal(request.id.toLowerCase(), requestID!.toLowerCase());
    assert.deepEqual(request.target, { kind: "page", id: pageID.toUpperCase() });
    assert.equal(request.pageVisionRevision, `0@${page.drawingStamp.actor}`);
    assert.equal(request.region, undefined);
  });
});

test("a stale expected ink revision cannot request a different current drawing", async () => {
  await withFixture(async (store, root) => {
    const page = await store.readPage(pageID);
    await rm(join(root, "previews", `${pageID}.vision.json`));
    await assert.rejects(readFreshPageVision(store, page, `9@${page.drawingStamp.actor}`), /Лист изменился/);
    assert.equal(await readdir(join(root, "collaboration", "render-requests")).catch(() => []).then(v => v.length), 0);
  });
});

test("an execution failure is not reported as an endlessly preparing map", async () => {
  await withFixture(async (store, root) => {
    const page = await store.readPage(pageID);
    await rm(join(root, "previews", `${pageID}.vision.json`));
    let id = "";
    await assert.rejects(readFreshPageVision(store, page), error => {
      assert.ok(error instanceof StoreError && "requestID" in error);
      id = String(error.requestID).toLowerCase();
      return true;
    });
    const request = JSON.parse(await readFile(join(root, "collaboration", "render-requests", `${id}.json`), "utf8"));
    await writeFile(join(root, "previews", "targets", `${id}.json`), JSON.stringify({
      request, status: "error", diagnostics: [{ kind: "render_error", message: "GPU unavailable" }],
      inkRegions: [], completedAt: 0,
    }));
    await assert.rejects(readFreshPageVision(store, page), error => {
      assert.ok(error instanceof StoreError);
      assert.match(error.message, /завершилась ошибкой: GPU unavailable/);
      assert.equal("requestID" in error, false);
      return true;
    });
  });
});

test("an evicted ready PNG reopens the same request instead of waiting forever", async () => {
  await withFixture(async (store, root) => {
    const page = await store.readPage(pageID);
    const receiptPath = join(root, "previews", `${pageID}.vision.json`);
    const saved = await readFile(receiptPath);
    await rm(receiptPath);
    let id = "";
    await assert.rejects(readFreshPageVision(store, page), error => {
      assert.ok(error instanceof StoreError && "requestID" in error);
      id = String(error.requestID).toLowerCase();
      return true;
    });
    await writeFile(receiptPath, saved);
    const request = JSON.parse(await readFile(join(root, "collaboration", "render-requests", `${id}.json`), "utf8"));
    const targetReceiptPath = join(root, "previews", "targets", `${id}.json`);
    await writeFile(targetReceiptPath, JSON.stringify({ request, status: "ready", diagnostics: [], inkRegions: [], completedAt: 0 }));
    await rm(join(root, "previews", `${pageID}.png`));
    const receipt = await readFreshPageVision(store, page);
    await assert.rejects(readVerifiedPageOverview(store, receipt, "faithful"), error => {
      assert.ok(error instanceof StoreError && "requestID" in error);
      assert.equal(String(error.requestID).toLowerCase(), id);
      return true;
    });
    await assert.rejects(readFile(targetReceiptPath), { code: "ENOENT" });
  });
});

test("rejects page pixels whose dimensions contradict the receipt", async () => {
  await withFixture(async (store, root) => {
    const onePixelPNG = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nH0AAAAASUVORK5CYII=",
      "base64",
    );
    const receiptPath = join(root, "previews", `${pageID}.vision.json`);
    const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as {
      previewPNG_SHA256: string;
    };
    receipt.previewPNG_SHA256 = createHash("sha256")
      .update(onePixelPNG)
      .digest("hex");
    await writeFile(receiptPath, JSON.stringify(receipt));
    await writeFile(join(root, "previews", `${pageID}.png`), onePixelPNG);

    const page = await store.readPage(pageID);
    const current = await readFreshPageVision(store, page);
    await assert.rejects(
      readVerifiedPageOverview(store, current, "faithful"),
      (error: unknown) =>
        error instanceof StoreError && /Размер изображения/.test(error.message),
    );
  });
});

test("rejects a map whose grid contradicts the rendered page", async () => {
  await withFixture(async (store, root) => {
    const receiptPath = join(root, "previews", `${pageID}.vision.json`);
    const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as {
      gridColumns: number;
    };
    receipt.gridColumns = 1;
    await writeFile(receiptPath, JSON.stringify(receipt));

    await assert.rejects(
      readFreshPageVision(store, await store.readPage(pageID)),
      (error: unknown) =>
        error instanceof StoreError &&
        /противоречивую геометрию/.test(error.message),
    );
  });
});

test("rejects a region whose points do not match its physical cells", async () => {
  await withFixture(async (store, root) => {
    const receiptPath = join(root, "previews", `${pageID}.vision.json`);
    const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as {
      regions: Array<{ contentPoints: { x: number } }>;
    };
    receipt.regions[0]!.contentPoints.x = 1;
    await writeFile(receiptPath, JSON.stringify(receipt));

    await assert.rejects(
      readFreshPageVision(store, await store.readPage(pageID)),
      (error: unknown) =>
        error instanceof StoreError &&
        /противоречивую геометрию/.test(error.message),
    );
  });
});
