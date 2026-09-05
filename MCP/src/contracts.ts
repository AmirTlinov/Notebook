import * as z from "zod/v4";

/** Every tool publishes this machine-readable envelope; owner-specific data
 * remains alongside it, with source schemas on the typed operation inputs. */
export const notebookResponseSchema = z.object({
  status: z.enum(["ready","saved","pending","error","snapshot_pending","placement_unavailable"]).optional(),
  code: z.string().optional().describe("revision_conflict: reread the explicit owner; target_missing: resolve its path; placement_unavailable: choose another surface; snapshot_pending: retain context and retry; action_id_conflict: use a fresh action ID for a different action."),
  message: z.string().optional(),
  target: z.object({kind:z.string(),id:z.string(),boardID:z.string().optional()}).optional(),
  expected: z.union([z.string(),z.array(z.object({target:z.json(),revision:z.string(),stateRevision:z.string().optional(),sourceRevision:z.string().optional()}))]).optional(),
  actual: z.string().optional(),
  visual: z.object({status:z.enum(["ready","pending"]),code:z.string().optional(),message:z.string().optional(),
    pngSHA256:z.string().optional(),surface:z.json().optional(),viewport:z.json().optional()}).optional(),
  cursor:z.string().optional(),
  changes:z.object({status:z.enum(["ready","baseline_unavailable"]),changed:z.array(z.string()),removed:z.array(z.string())}).optional(),
  references:z.array(z.json()).optional(),
  connection:z.object({status:z.enum(["connected","disconnected","unavailable"])}).passthrough().optional(),
  request:z.object({id:z.uuid(),target:z.json(),sourceRevision:z.string(),region:z.json().optional(),pageIndex:z.number().int().nonnegative()}).passthrough().optional(),
  diagnostics:z.array(z.object({kind:z.string(),elementID:z.string().optional(),message:z.string()})).optional(),
  publication:z.object({
    saved:z.object({status:z.literal("confirmed")}),
    receivedByIPad:z.object({status:z.enum(["confirmed","awaiting_device"])}),
    snapshots:z.array(z.json()).describe("Each snapshot names its own exact source hash and region; a saved action alone supplies no image evidence."),
    shownOnIPad:z.object({status:z.enum(["confirmed","awaiting_display"]),visibleRegions:z.array(z.json())}),
  }).optional(),
}).passthrough();
