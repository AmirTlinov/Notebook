import assert from "node:assert/strict";
import test from "node:test";
import { offsetWorld, TILE_SIZE, worldPointSchema, sceneBoundsSchema } from "../src/spatial.js";
import { visibleBounds } from "../src/store.js";
import type { SessionPresence } from "../src/domain.js";

test("both exact tile endpoints survive JSON and retain normalized local coordinates", () => {
  for (const tileX of [0, 1, -1, Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]) {
    const point = {tileX, tileY: tileX === 0 ? 0 : -tileX, localX: 0.25, localY: 100};
    assert.deepEqual(worldPointSchema.parse(JSON.parse(JSON.stringify(point))), point);
  }
});

test("a viewport retains an exact anchor and the full frame across both world edges", () => {
  for (const sign of [-1, 1]) {
    const anchor = {tileX:sign * Number.MAX_SAFE_INTEGER,tileY:sign * Number.MAX_SAFE_INTEGER,
      localX:sign < 0 ? 0 : TILE_SIZE - 1,localY:sign < 0 ? 0 : TILE_SIZE - 1};
    const presence = {camera:{center:anchor,scale:0.0125},viewport:{x:834,y:1194}} as SessionPresence;
    const bounds = visibleBounds(presence);
    assert.deepEqual(bounds,{anchor,region:{x:-33360,y:-47760,width:66720,height:95520}});
    assert.deepEqual(sceneBoundsSchema.parse(JSON.parse(JSON.stringify(bounds))),bounds);
    assert.equal(sceneBoundsSchema.safeParse({...bounds,region:{...bounds.region,x:10_000_001}}).success,false);
    assert.equal(sceneBoundsSchema.safeParse({origin:anchor,width:834,height:1194}).success,false,
      "A retired origin-only read shape is not a second geometry contract");
  }
});

test("rounded input outside the continuous safe range never becomes an owner", () => {
  for (const value of ["9007199254740992", "9007199254740993", "9223372036854775807", "-9223372036854775808"]) {
    const point = JSON.parse(`{"tileX":${value},"tileY":0,"localX":0,"localY":0}`);
    assert.equal(worldPointSchema.safeParse(point).success, false);
  }
  for (const localX of [-1, TILE_SIZE, Infinity, NaN]) {
    assert.equal(worldPointSchema.safeParse({tileX:0,tileY:0,localX,localY:0}).success, false);
  }
});

test("offset across the last exact tile refuses instead of silently rounding", () => {
  const point = {tileX:Number.MAX_SAFE_INTEGER,tileY:0,localX:0,localY:0};
  assert.throws(() => offsetWorld(point, TILE_SIZE, 0));
  assert.throws(() => offsetWorld(point, Infinity, 0));
  assert.equal(offsetWorld(point, -1, 0).tileX, Number.MAX_SAFE_INTEGER - 1);
});

test("stroke-local offsets use the full exact range on both axes", () => {
  for (const tile of [1_000_000_000_001, -1_000_000_000_001, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
    const point = {tileX: tile, tileY: -tile, localX: 256, localY: 512};
    assert.deepEqual(offsetWorld(point, 100, 120), {...point, localX: 356, localY: 632});
    assert.deepEqual(offsetWorld(point, 160, 190), {...point, localX: 416, localY: 702});
  }
  for (const axis of ["x", "y"] as const) {
    for (const sign of [-1, 1]) {
      const point = {tileX: axis === "x" ? sign * Number.MAX_SAFE_INTEGER : 0,
        tileY: axis === "y" ? sign * Number.MAX_SAFE_INTEGER : 0,
        localX: axis === "x" && sign > 0 ? TILE_SIZE - 1 : 0,
        localY: axis === "y" && sign > 0 ? TILE_SIZE - 1 : 0};
      assert.throws(() => offsetWorld(point, axis === "x" ? sign * 2 : 0, axis === "y" ? sign * 2 : 0));
    }
  }
});
