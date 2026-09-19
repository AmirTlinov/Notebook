# Incoming transaction owner window

`NotebookReplicationStore.applyRemoteChange` reads one admitted manifest in pages
of at most 64 records. Catalog, placement, board/page elements, document programs
and states, shared context, and spatial ink are merged by changed owner addresses.
Receipts and archived requests remain bounded, independent logical files.

`WorkspaceReplication`, `BoardReplication`, and `PageReplication` own their typed
merges. `NotebookIncomingRecords` supplies the incoming-address index and subtree
publication. Conflict decisions remain with `CollaborativeContent`,
`WorkspacePlacement`, `NotebookPageOrderRegister`, and typed ink/computation owners.
An element subset cannot author a reorder of an entire surface. Ordinary field
changes do not enumerate neighbors; a real reorder reads ID/position metadata.

## Atomicity and dependencies

All owners execute inside the same `commandTransaction`. Content, dependencies,
local journal, incoming cursor, and receipt commit or roll back together.
A late owner failure leaves no earlier partial records; exact retry does not
create a second contribution.

Publication follows dependencies: catalog, document dimensions, then other content
and placements. New document placement reads the published paper size.
Canonical SQL membership is checked after merging the catalog. A delayed package
cannot resurrect a removed owner.

Archived agent requests are validated after their dependencies. A transaction-local
SQL table stores request UUIDs and prior execution metadata, not every source or
answer body. Pages contain at most 64 rows and temporary SQL has a 2 MiB cache.
The validator reads only a new answer tail and checks the original pinned source.

## Scope and checks

Explicit whole-document reads, exports, and snapshots retain their full-input
semantics. An element edit avoids unrelated drawing, computation, and elements.
Concurrent page order normalization belongs to the affected notebook; arbitrary
reorder is not a constant-time promise. Retention needs its own checkpoint policy.

`NotebookReplicationOwnerWindowTests` exercises two isolated stores, real staging,
SQL-result row counts, multi-page manifests, late failures, repeated delivery,
and archived answer continuations. Storage acceptance and actual display on a
second device are separate receipts; see [verification](verification.md).
