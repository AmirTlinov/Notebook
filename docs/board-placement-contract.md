# One physical placement per item

`BoardDocument.placements` owns durable placement of cards, notebooks, and documents.
Each `WorkspacePlacement` names an item and preserves immutable causal movement heads:
position, order, stack membership, or explicit removal. An accepted movement observes
earlier heads. Receipt of a package does not author another human movement.

Merging unions heads and removes only causally dominated ones. Concurrent heads use
human priority and stable version order. A losing independent intention remains
evidence until explicitly observed, making replay and delivery order converge.

`freeItems` and `stacks` are derived views. Empty stacks are hidden; singleton or
over-limit members appear free without rewriting their intended membership.
Moving another member does not rewrite a remaining card's coordinates.
A stack UUID has one immutable anchor.

SQLite stores the complete register at `board/placements/@item`. The physical index,
bounded scene reads, agent context, and undo use it. Creation owns individual
placements, not an entire neighboring stack.

## Parent ownership and revisions

One item has one physical board owner. Concurrent live placement under two parents
fails with `ownership_conflict`. A normal gesture does not change physical parent.
An explicit transfer removes the old placement and adds the new one atomically.
Index deletion removes only its own row, preserving an owner already installed by
another address in the same transaction. A mismatch rolls back the whole command.

`BoardDocument.stamp` records authorship, not a complete edit precondition.
`NotebookStore.boardContentRevision` computes the maintained SQL fingerprint of
the board's addresses. The root contribution excludes `portalCamera` and
`portalStamp`; spatial ink has separate addresses. Camera and Pencil therefore
do not cause false content-edit conflicts.

Scene and MCP reads return that fingerprint with their content from one snapshot.
A bounded window cannot derive a full revision from its subset. Unpublished local
edits invalidate the accepted revision; publication and receipt acquire the new
revision through the same SQL owner.

## Native drop and history boundary

`NotebookNativeCommand<WorkspacePlacement>` validates the captured registers and
complete bounded stack membership before obtaining the current board revision
inside the existing action transaction. An unrelated edit may proceed; a changed
member, hidden concurrent head, transfer, or added sibling rejects the old contact.
One drop can contain unstack/move and stack as one action and one history entry.
New stack identity derives from the action and operation index, rather than a
second random identity in persistence. The same retained native-command owner
handles uncertain responses for element and placement edits.

Undo authors a new register. Redo uses the inverse's exact gate (or its proved
already repeated predecessor), requires the entire placement frontier, and authors
another register with the retained pose and stack ID. It never reinstalls an old
register. Both directions retain causal observations, so delayed delivery cannot
restore an earlier position. Native gesture integration is a separate remaining
GUI-295 boundary; the Core command alone does not establish installed UI behavior.

## Historical-format admission

`migrateBoardPlacements` upgrades the former representation transactionally after
all known devices acknowledge outgoing changes. Placement inherits the real prior
body version, not an aggregate header version. Content, blobs, history, context,
ink, camera, drafts, identity, and cursors are preserved. The receipt records source
cursor and before/after hashes; re-admission is idempotent.

Old journal entries are not relabeled as new packets. A peer before the transition
needs a current checkpoint; acknowledgement cannot skip missing edits. Historical
archives cannot replace the active workspace or overwrite later iPad work.

Old receipts remain immutable. A provable single free-item movement can be translated
to current undo. Ambiguous legacy stack/batch ownership returns
`placement_migration_boundary`. Current version numbers belong to
[transport](transport-contract.md).

## Presentation and checks

Accepted geometry immediately defines the body, corners, and hit region. Background
tiles cannot restore an old placement. Pixel admission remains with
[scene publication](scene-allocation-contract.md) and [shared context](shared-context-contract.md).

`BoardMergeOwnershipTests`, `PlacementActionOwnershipTests`,
`NotebookLiveScenePublicationTests`, `NotebookLiveGesturePresentationTests`, and
`NotebookBoardContentRevisionTests` cover convergence, transfer, undo, stale versions,
and gestures against delayed composition. Element source/style concurrency is a
separate contract and task; placement acceptance does not close all collaboration work.
See [verification](verification.md).
