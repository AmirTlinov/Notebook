import assert from "node:assert/strict";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { operationSchema } from "../src/actions.js";

const target = { kind: "page", id: randomUUID() };
const graphic = { shape: "ellipse", style: { stroke: { red: 0, green: 0, blue: 0 }, strokeWidth: 2 },
  label: "+", representation: "geometry", visible: true, sourceInkIDs: [randomUUID()] };

test("retained measured layers and native page text use the ordinary typed element action", () => {
  const freehand = {layers:[{tool:"pen",color:{red:0,green:0.2,blue:0.8},vertices:[
    {x:0,y:0,opacity:0.2},{x:1,y:0,opacity:0.8},{x:1,y:1,opacity:0.8}]}]};
  const values = {kind:"graphic",source:"",frame:{x:10,y:10,width:80,height:80},graphic:{...graphic,shape:"freehand",freehand}};
  assert.deepEqual(operationSchema.parse({kind:"convertInkToElement",target,id:"ink",values}).values,values);
  const text = {kind:"nativeText",source:"Подпись",frame:values.frame,textStyle:{fontSize:24,weight:0.5,red:0,green:0,blue:0,alpha:1}};
  assert.deepEqual(operationSchema.parse({kind:"insertElement",target,id:"text",values:text}).values,text);
  assert.throws(() => operationSchema.parse({kind:"insertElement",target,id:"bad",values:{...values,
    graphic:{...values.graphic,freehand:{layers:[{...freehand.layers[0],tool:"pencil"}]}}}}));
});

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
  for (const shape of ["rectangle", "triangle", "diamond", "plus"]) {
    const values = { kind: "graphic", source: "", frame: { x: 10, y: 10, width: 80, height: 80 }, graphic: { ...graphic, shape } };
    assert.deepEqual(operationSchema.parse({ kind: "insertElement", target, id: shape, values }).values, values);
  }
});

test("polygon corners use the same typed action and allow an explicit reset", () => {
  for (const vertices of [[{x:0,y:0},{x:1,y:0},{x:0.5,y:1}],null]) {
    const values = {graphic:{vertices}};
    assert.deepEqual(operationSchema.parse({kind:"updateElement",target,id:"triangle",values}).values,values);
  }
  for (const vertices of [[],[{x:-1,y:0},{x:1,y:0},{x:0.5,y:1}]]) {
    assert.throws(()=>operationSchema.parse({kind:"updateElement",target,id:"triangle",values:{graphic:{vertices}}}));
  }
});

test("geometry edits admit a physical radius and longitudinal bend position", () => {
  for (const graphic of [{cornerRadius:24}, {cornerRadius:null}, {connection:{bendPosition:0.7,bend:36}}]) {
    assert.doesNotThrow(() => operationSchema.parse({kind:"updateElement",target,id:"shape",values:{graphic}}));
  }
  for (const graphic of [{cornerRadius:-1}, {cornerRadius:Infinity}, {connection:{bendPosition:1.1}}]) {
    assert.throws(() => operationSchema.parse({kind:"updateElement",target,id:"shape",values:{graphic}}));
  }
});

test("native text size covers explicit screen points across the full camera range", () => {
  const values = (fontSize: number) => ({textStyle:{fontSize,weight:0.5,red:0,green:0,blue:0,alpha:1}});
  for (const size of [12/4,24/0.03787425024543671,72/0.0125]) {
    assert.deepEqual(operationSchema.parse({kind:"updateElement",target,id:"text",values:values(size)}).values,values(size));
  }
  for (const size of [2.99,5761]) assert.throws(() => operationSchema.parse({kind:"updateElement",target,id:"text",values:values(size)}));
});
