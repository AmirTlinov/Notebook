# Addressed edits to an existing page element

`NotebookStore.actionSourceProjection` returns a `CollaborationWorkspace` with an
explicit set of partially read pages. `updateElement` and `setElementState` read
the header, named elements, and their causal versions within a shared 4,096-row,
4 MiB allowance for the action. Order is read as a version, not a neighbor-ID array.
Geometry permission checks the addressed element's previous frame.
`sourceRevision` remains the full physical SQL revision.

`NotebookReferenceIndex` includes the page owner. Headers, elements, computation,
and drawing actions contribute independently. Editing an element need not reconstruct
neighbor programs or ink to validate the page revision. A page edit does not change
the cover's identity. A partial projection must carry a valid full identity rather
than invent one from its subset.

`NotebookPageElementProjection` contains no ink or computation. It cannot be decoded
as a complete `PageDocument`, used as pixel evidence, or admitted as a full archive.
`PageDocument` retains common element-size validation. Unread drawing is preserved.

## Versions, publication, and undo

Creation establishes original causal element versions. Full publication and the
external converter can make implicit versions explicit at their original counter.
Updating one element does not assign its new clock to an invisible neighbor.

`publishProjectionEdits` writes only the baseline difference. Missing ink and
computation in both partial projections do not delete stored addresses.
Element positions and neighboring bodies remain intact. New causal fields are
charged against the complete owner's limit.

Undo reads the same addressed elements and versions. Later human fields survive;
independent program-state edits do not prevent undo of earlier text.
Replay returns the durable receipt. Resource exhaustion, stale physical revision,
or a transaction failure cannot publish a partial result.

## Verification and scope

Regressions use corrupt unread ink/computation, a large neighboring program,
99,000 causal records, geometry permissions, budget exhaustion, and commit faults.
SQL accounting includes final checks and commit.

Insertion, removal, ordering, ink commands, and whole-item creation undo have
separate input/ownership contracts. See [replication](replication-owner-window.md)
for incoming page delivery and [verification](verification.md) for exact evidence.
