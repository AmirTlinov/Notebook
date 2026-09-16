import assert from "node:assert/strict";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { operationSchema } from "../src/actions.js";

const target = { kind: "page", id: randomUUID() };
const graphic = { shape: "ellipse", style: { stroke: { red: 0, green: 0, blue: 0 }, strokeWidth: 2 },
  label: "+", representation: "geometry", visible: true, sourceInkIDs: [randomUUID()] };

test("nb.action keeps the native geometry and immutable source references, not SVG", () => {
  const values = { kind: "graphic", source: "", frame: { x: 10, y: 10, width: 80, height: 80 }, graphic };
  const result = operationSchema.parse({ kind: "convertInkToElement", target, id: "circle", values });
  assert.deepEqual(result.values, values);
  const edit = operationSchema.parse({ kind: "updateElement", target, id: "circle", values: { graphic: { label: "?" } } });
  assert.deepEqual(edit.values, { graphic: { label: "?" } });
});

test("a patch cannot rewrite source measurements or impersonate native human authorship", () => {
  for (const values of [{ graphic: { sourceInkIDs: [randomUUID()] } }, { graphic: { human: true } }, { human: true }]) {
    assert.throws(() => operationSchema.parse({ kind: "updateElement", target, id: "circle", values }));
  }
  assert.throws(() => operationSchema.parse({ kind: "convertInkToElement", target, id: "circle", human: true,
    values: { kind: "graphic", source: "", frame: { x: 10, y: 10, width: 80, height: 80 }, graphic } }));
});
