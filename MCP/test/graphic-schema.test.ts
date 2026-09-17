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

test("connection patches own each endpoint independently and reject unknown geometry", () => {
  const endpoint = {point:{x:0,y:0},binding:{elementID:"node",normalizedAnchor:{x:0.5,y:0.5},isExact:false,isPrecise:true}};
  for (const connection of [{start:endpoint},{end:{point:{x:100,y:0}}},{bend:75},{startArrowhead:"diamond",endArrowhead:"none"}]) {
    const values = {graphic:{connection}};
    assert.deepEqual(operationSchema.parse({kind:"updateElement",target,id:"arrow",values}).values,values);
  }
  for (const connection of [{bend:Infinity},{route:"unknown"},{start:{...endpoint,binding:{...endpoint.binding,isExact:"yes"}}}])
    assert.throws(()=>operationSchema.parse({kind:"updateElement",target,id:"arrow",values:{graphic:{connection}}}));
});

test("native rectangles and pluses use the existing graphic command", () => {
  for (const shape of ["rectangle", "plus"]) {
    const values = { kind: "graphic", source: "", frame: { x: 10, y: 10, width: 80, height: 80 }, graphic: { ...graphic, shape } };
    assert.deepEqual(operationSchema.parse({ kind: "insertElement", target, id: shape, values }).values, values);
  }
});
