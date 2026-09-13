import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { actionResult } from "./actions.js";
import { runBridge } from "./bridge.js";
import { notebookResponseSchema } from "./contracts.js";
import { worldPointSchema } from "./spatial.js";
import { NotebookStore } from "./store.js";

const region = z.object({ origin: worldPointSchema, width: z.number().min(1).max(100_000), height: z.number().min(1).max(100_000) }).strict();
export const presentationStepSchema = z.object({
  duration: z.number().min(0.5).max(10).default(3).describe("Seconds to show this step, including a short fade; total script at most 60 seconds."),
  transition: z.number().min(0).max(1).default(0.3),
  camera: z.object({ center: worldPointSchema, scale: z.number().min(0.0125).max(4) }).strict().optional(),
  focus: region.optional().describe("Fit this board-world region with a margin, instead of computing center and scale yourself. Does not open another document or board."),
  svg: z.string().min(1).max(48 * 1024).optional().describe("Temporary vector SVG with viewBox. No scripts, external resources, embedded HTML or images. SVG animation is allowed."),
  bounds: region.optional().describe("Board-world placement of the SVG. Required with svg. Use the observed camera/viewport to place over visible paper; not screen pixels."),
}).strict().refine(step => !(step.camera && step.focus) && step.transition <= step.duration
  && !!step.svg === !!step.bounds && !!(step.camera || step.focus || step.svg), "Specify camera OR focus, or svg with bounds.");

export const presentationSchema = z.object({
  presentation_id: z.uuid().optional().describe("Stable request ID. With no steps, reads its receipt; reuse the same ID and payload after an uncertain reply, never a new ID."),
  view: z.object({ deviceID: z.uuid(), sessionID: z.uuid(), sequence: z.number().int().nonnegative(), nonce: z.uuid() }).strict().optional(),
  steps: z.array(presentationStepSchema).min(1).max(12).optional().describe("A short sequential presentation script. Every step replaces the previous temporary SVG; no saved content is changed."),
  cancel: z.boolean().optional(),
}).strict().refine(value => value.steps ? !!value.presentation_id && !!value.view && !value.cancel
  && value.steps.reduce((sum, step) => sum + step.duration, 0) <= 60
  : !value.view && (!value.cancel || !!value.presentation_id), "Read current view first, then pass its view and a new presentation_id with steps; cancel names an ID.");

export function registerPresentationTool(server: McpServer, store: NotebookStore): void {
  server.registerTool("notebook_present", {
    title: "Show a detail with camera and temporary SVG",
    description: "Explicitly show the user something in foreground Notebook: smoothly pan/zoom the existing camera and display disappearing SVG. Call without arguments to get the current iPad view capability and presence, then send steps with that view. This is NOT a read or a saved edit. Human touch, Pencil, navigation and disconnect interrupt it; it never queues behind input, changes selection, opens files, or replays after reconnect. Receipt sent is not displayed: read the same presentation_id to see playing/completed/interrupted. Prefer one short script over many tool calls.",
    inputSchema: presentationSchema, outputSchema: notebookResponseSchema.extend({
      status: z.enum(["ready", "error", "sent", "playing", "completed", "interrupted", "rejected", "unavailable"]).optional(),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false, idempotentHint: true },
  }, input => actionResult(() => runBridge(store.socketPath, {
    command: "presentation", actionID: input.presentation_id, cancel: input.cancel,
    ...(input.steps ? { presentation: { id: input.presentation_id, view: input.view, steps: input.steps } } : {}),
  })));
}
