# Shared actions

A `CollaborationAction` is one complete contribution: summary, reviewed references,
owner versions and ordered operations. PageDocument, BoardDocument and
DocumentDocument retain content ownership. Receipts record field changes and causal
versions for precise undo.

## Execution and authority

There are **three** public MCP tools: `notebook_context`, `notebook_execute` and
`notebook_import_program`. Context reads/help, script execution and package-byte
admission are separate. Import-ready is not content publication.
The [JavaScript SDK](notebook-javascript-api.md) provides reads, loops, atomic actions
and stable effects. `MCP/src/actions.ts` owns operation schemas; MCP sends to the
existing Mac owner and never opens SQLite. `NotebookScriptCoordinator` uses the
shared writer; `CollaborationStore` applies content.

Creation preserves human selection. Camera is read context, not a mutation target.
`NotebookActionSubmission` freezes the raw fingerprint before kind lookup/Markdown.
The trusted markup worker prepares off-SQL; the transaction rechecks versions,
identity and allowed derived fields before atomic content/undo publication.
Stale preparation returns revision_conflict, not an invented identity conflict.
An identical run/key request reads its receipt; changed payload conflicts.
Historical raw retries without an original fingerprint return
`request_identity_unavailable`.

## Causal merge and undo

Source and derived HTML form one causal content field; style, geometry and state
have separate versions. Registers preserve immutable concurrent author-version/value
heads and their observed causal context. First discard superseded heads, then prefer
a surviving human head, then Lamport order. Receiving data is not new authorship.
A losing concurrent value can become visible after a later causal continuation.
Existence/deletion does not rewrite the deleted member's source. Delivery never
turns a composite order into a new authored edit. Previously lost legacy history
cannot be reconstructed by this algorithm.

Composite results receive a changed aggregate revision even when original counters
match. Undo checks both field value and authorship, restores only surviving owned
fields and reports later adopted content/dependencies as preserved. Repeated undo
reads the same receipt. See [editable graphics](editable-graphics-contract.md) and
[spatial commands](agent-spatial-command-contract.md).

## Reads, attention and navigation

`nb.observe` returns bounded content immediately; visual status separately describes
a verified PNG. `readMany` shares one SQL snapshot. Whole page/document reads remain
explicit, while addressed element/block reads avoid unrelated bodies.
`nb.search` returns exact references and paths.

`nb.point` saves an interpretation with reviewed source identity.
`nb.render` prepares an exact target/region without moving camera.
`nb.place` uses the same ink map and geometry; pending raster means pending, not
free space. Rendering shares native measured ink and eraser semantics on Mac/iPad.

Shared context stores immutable references/replies. An action with contextID uses
that context's saved scope; a standalone action uses its own references rather than
silently adopting current selection. Selecting/clearing context does not erase its
history. See [shared context](shared-context-contract.md).

`ReferenceVision` distinguishes checking, current, changed, review_required and
target_missing. A region's baseline fingerprints final pixels and intersecting
content independently of the PNG cache and owner's later position. If source changes
before its first exact capture, require review instead of substituting new pixels.

Explicit Show uses existing navigation and a bounded return stack. SQL-addressed
location resolution does not treat absence from a partial scene as deletion.
The latest navigation intent rechecks input generation after accepted input drains;
new human contact/navigation cancels the old intent. Return is removed only after
camera settlement, not a canceled animation. Temporary agent presentation is
[an explicit separate request](agent-presentation-contract.md).

## Saved, received and shown

Content and delivery journal commit together. Direct/cloud replication use
[immutable addressed manifests](transport-contract.md), not the historical full-tree
network envelope.

Device receipt identity is `actionVersion`: SHA-256 of the canonical action receipt
in domain `notebook.action-delivery.v1`, including undo phase. Receipt and all result
revisions are rechecked in one writer transaction. Shown additionally requires the
exact installed source, active-window frame and covered visible region. Multiple
results accumulate genuinely visited regions. Different action phases cannot merge
display proof; late old acknowledgments cannot overwrite the current phase.

Historical receipts without actionVersion remain readable but do not confirm a
current effect. Receiving the same version again is a no-op. Modern delivery ACKs
follow their source action in the journal; unknown versions reject the whole package.

Undo with zero restored fields and no revisions returns
`publication.shownOnIPad: "not_required"` and
`shownOnIPadReason: "undo_without_visual_changes"`.
This is no new image requirement, not proof that the original action or notification
was seen. Receipt status reads neither rewrite history nor start rendering.

## Placement and active input

`nb.place` considers one surface, its revision, at most 32 new items and 32 explicitly
movable targets. It first preserves existing positions, then tries moving only admitted
ones. Board search is bounded to 2048×2048 points around returned worldOrigin;
paper uses physical bounds. Stacks remain units.
Ready returns placements, moves, expected versions, contextID and additionalOwners
without writing. Failure returns empty results and a continuation suggestion.

Transaction repeats scope, owner-version and sourceRevision checks inside SQL.
References or exact additional owners authorize existing geometry changes; a read
basis alone does not. A board reference is not blanket permission to move every
cover. Fresh post-read edits require recalculation, never silently refreshed versions.

`NotebookInputGate` tracks accepted native contacts without stealing gestures.
`NotebookInputActivity` publishes busy owners; Core rechecks inside apply/undo.
Mac waits outside SQL for at most four seconds. `input_active`,
`status:pending`, `acceptance:not_saved` means no saved or hidden queued action:
retry the same package after contact, with versions still subject to validation.
Already-saved receipts remain readable immediately.

A busy board protects its relevant surfaces while independent boards remain usable.
Incoming changes coalesce until local input/publication ends, then merge and ACK.
Disconnect clears only the corresponding transient remote barrier. Snapshot publication
also checks idle state.

## Agent ink and compact action reads

`appendInkStroke` writes ordinary measured pen ink to a page, board or cover.
Board points require an exact worldOrigin; page/cover points and half-width must fit
paper. Defaults: width 2, opacity 1, black. Width is positive and ≤128; color/opacity
are 0–1. A stroke has 1–8,192 points and a whole action at most 100,000.
Missing stroke ID derives stably from action/index. This is not an agent eraser.
Both content and ink basis are required; invalid scope/version/point rejects the batch.
Undo names stroke UUIDs, preserving later human/agent strokes.

`NotebookActionReadModel` supplies operation addresses, revisions, result bounds,
field hashes and preserved-continuation addresses without large bodies/undo values.
The writer derives it atomically from the full receipt; `action_read_models` is
a local hash-bound index, not replicated source. Mismatch forbids stale publication.
History preparation is off-main, generation-checked and invalidated by real source
changes. Status lookup addresses known render requests rather than scanning a list.

Native text, formatting, fitted geometry and clipboard panels use existing TextKit,
selection and element-command owners. Current toolbar/eraser behavior is documented
in [page ink](page-ink-conflict-contract.md); historical UI descriptions are not a
second specification.

## Checks

Use focused Core/MCP/native checks and the affected real gesture:
`cd MCP && npm run check && npm test && npm run smoke`, with isolated storage for
contract tests, and [selected verification](release-build-contract.md#verification-selection).

Frame-monitor callbacks measure main-thread servicing, not GPU FPS.
[Historical runs and migration observations](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/collaboration.md)
remain immutable; [verification](verification.md) owns current installed scope.
