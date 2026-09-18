import * as z from "zod/v4";
import { referenceSchema } from "./actions.js";
import { worldPointSchema } from "./spatial.js";

const attentionReference = referenceSchema.refine(ref => !["workspace","codeFragment"].includes(ref.target.kind)
  && ref.revision.length > 0 && ref.revision.length <= 256
  && (ref.target.kind !== "board" || ref.elementID != null || ref.region != null), "Attention names a current visible material or an explicit board region.");

const region = z.object({ origin: worldPointSchema, width: z.number().min(1).max(100_000), height: z.number().min(1).max(100_000) }).strict();
export const presentationStepSchema = z.object({
  duration: z.number().min(0.5).max(10).default(3).describe("Seconds to show this step, including a short fade; total script at most 60 seconds."),
  transition: z.number().min(0).max(1).default(0.3),
  camera: z.object({ center: worldPointSchema, scale: z.number().min(0.0125).max(4) }).strict().optional(),
  focus: region.optional().describe("Fit this board-world region with a margin, instead of computing center and scale yourself. Does not open another document or board."),
  attention: z.array(attentionReference).min(1).max(16).optional().describe("Hold material attention on these exact current references without moving the camera or changing human selection. Duration, cancellation and human interruption use this same presentation lifecycle."),
  svg: z.string().min(1).max(48 * 1024).optional().describe("Temporary vector SVG with viewBox. No scripts, external resources, embedded HTML or images. SVG animation is allowed."),
  bounds: region.optional().describe("Board-world placement of the SVG. Required with svg. Use the observed camera/viewport to place over visible paper; not screen pixels."),
}).strict().refine(step => !(step.camera && step.focus) && step.transition <= step.duration
  && !!step.svg === !!step.bounds && !!(step.camera || step.focus || step.svg || step.attention), "Specify attention, camera OR focus, or svg with bounds.");
