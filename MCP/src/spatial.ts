import * as z from "zod/v4";
import type { WorldPoint } from "./domain.js";

export const TILE_SIZE = (132 / 2.54 / 2) * 256;

/** Same continuous exact JSON address range as NotebookCore.WorldPoint. */
export const worldPointSchema = z.object({
  tileX: z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
  tileY: z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
  localX: z.number().finite().min(0).lt(TILE_SIZE),
  localY: z.number().finite().min(0).lt(TILE_SIZE),
}).strict();

export function offsetWorld(point: WorldPoint, x: number, y: number): WorldPoint {
  worldPointSchema.parse(point);
  if (!Number.isFinite(x) || !Number.isFinite(y)) throw new RangeError("World offset must be finite");
  const rawX = point.localX + x, rawY = point.localY + y;
  const dx = Math.floor(rawX / TILE_SIZE), dy = Math.floor(rawY / TILE_SIZE);
  if (!Number.isSafeInteger(dx) || !Number.isSafeInteger(dy)) throw new RangeError("World offset exceeds the exact tile range");
  return worldPointSchema.parse({ tileX: point.tileX + dx, tileY: point.tileY + dy,
    localX: rawX - dx * TILE_SIZE, localY: rawY - dy * TILE_SIZE });
}
