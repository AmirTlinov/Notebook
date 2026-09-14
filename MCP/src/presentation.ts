import * as z from "zod/v4";
import { worldPointSchema } from "./spatial.js";

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
