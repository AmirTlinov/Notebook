import * as z from "zod/v4";

const target = z.object({kind:z.enum(["workspace","board","cover","page","document"]),id:z.uuid(),boardID:z.uuid().optional()});
const expected = z.object({target,revision:z.string(),stateRevision:z.string().optional(),sourceRevision:z.string().optional(),inkRevision:z.string().optional()});
const fieldPath = z.array(z.union([
  z.object({field:z.object({_0:z.string()})}),
  z.object({member:z.object({_0:z.string()})}),
  z.object({order:z.object({})}),
]));
const action = z.object({
  id:z.uuid(),contextID:z.uuid(),summary:z.string(),references:z.array(z.json()),createdAt:z.number().describe("Seconds since 2001-01-01T00:00:00Z, the native action journal epoch."),
  revisions:z.array(expected),
  continuations:z.array(z.object({file:z.string(),path:fieldPath,author:z.enum(["human","agent","removed"])})),
  results:z.array(z.object({kind:z.string(),target,id:z.string().optional(),frame:z.json().optional()})),
  undo:z.object({restored:z.number().int(),preserved:z.array(z.object({file:z.string(),path:fieldPath})),completedAt:z.number().describe("Seconds since 2001-01-01T00:00:00Z.")}).optional(),
});

/** Every tool publishes this machine-readable envelope; owner-specific data
 * remains alongside it, with source schemas on the typed operation inputs. */
export const notebookResponseSchema = z.object({
  status: z.enum(["ready","saved","pending","error","snapshot_pending","placement_unavailable"]).optional(),
  code: z.string().optional().describe("revision_conflict: reread the explicit owner; target_missing: resolve its path; placement_unavailable: choose another surface; snapshot_pending: retain context and retry; action_id_conflict: use a fresh action ID for a different action; input_active: the action was not saved; retry the same request after contact ends; composition_scope: restrict movement to context sources or explicitly list additional_owners."),
  message: z.string().optional(),
  acceptance: z.literal("not_saved").optional().describe("A pending input response has not queued or accepted the action. Retry the identical request after contact ends."),
  action:action.optional(),
  target: z.object({kind:z.string(),id:z.string(),boardID:z.string().optional()}).optional(),
  expected: z.union([z.string(),z.array(z.object({target:z.json(),revision:z.string(),stateRevision:z.string().optional(),sourceRevision:z.string().optional(),inkRevision:z.string().optional()}))]).optional(),
  actual: z.string().optional(),
  placements: z.array(z.object({id:z.string(),frame:z.object({x:z.number(),y:z.number(),width:z.number().positive(),height:z.number().positive()}),worldOrigin:z.json().optional()})).optional(),
  moves: z.array(z.object({kind:z.enum(["moveItem","updateElement"]),target,id:z.string(),values:z.record(z.string(),z.json())})).optional(),
  contextID: z.uuid().optional(),
  additionalOwners: z.array(target).optional(),
  sourceRevision: z.string().optional(),
  requestID: z.uuid().optional().describe("Stable derivative request identity; retry the same physical owner without changing the human camera."),
  retryAfterMilliseconds: z.number().int().nonnegative().nullable().optional(),
  suggestion: z.string().optional(),
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
