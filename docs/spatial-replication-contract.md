# Addressed spatial-ink delivery

Item geometry follows the [placement contract](board-placement-contract.md).
Moving an item does not re-author its ink.

`NotebookReplicationStore` delegates spatial records to
`NotebookStore.publishSpatialInk`, the same publisher used by native contact.
`SpatialInkReplication` validates manifest pages of 64 addresses, the journal
root, UUID headers, and immutable spans. Incoming delivery does not reconstruct
and republish the complete local journal.

A new action requires its header and spans. An existing action retains its UUID,
tool, color, original causal version, and measured points; only activity may
change under a later version. Conflicting values for one version, mismatched UUIDs,
history deletion, and a damaged root are rejected. Old echoes cannot reactivate
an undone stroke. Original versions determine visible order without renumbering
unrelated local actions.

Content, receipt, and incoming cursor share one transaction. An ambiguous response
after commit is resolved by exact retry. Native additions and reactivation require
live owners, while delivery may retain historical measurements after cover removal.

## Retained sources and live membership

Deletion separates live membership from an already admitted source:
a notebook retains PAGE and typed order, a document retains its source/state pair,
and a child board retains its typed node. Existing mergers can accept later fields
without putting the item back into the catalog.

First admission of a hidden source on a fresh peer needs a complete baseline in
one snapshot or manifest: PAGE drawing/order/birth/exists, both document roots with
kind/exists, or a board node with kind/exists. Metadata alone, half a document pair,
or a tombstone alone cannot create an orphan. Dependencies are checked before
commit and ACK, independent of UUID ordering.

Ordinary reads, search, link resolution, and local writes require live membership.
A retained source stays hidden until an authorized causal undo restores it.
Reusing an occupied UUID is rejected by its existing causal birth/exists records.

Typed placement proofs and retired-page lookup are derived indexes. Rebuilding
them preserves canonical content, UUIDs, receipts, and read/delivery cursors.
Current wire and manifest versions are defined in the [transport contract](transport-contract.md).

Page-order shape and unique-value admission are separate derived proofs. A received
single-root append validates the changed positions against the admitted prefix,
including a duplicate of a UUID hidden in the unchanged prefix, rather than loading
every earlier membership. Exact storage-owned causal-field counts replace a scan
of that same owner during admission. Concurrent union/removal still constructs its
required ordered value; a partial membership is never declared complete. Proofs,
counts, material and incoming cursor commit atomically. Rebuilding these local
indexes preserves accepted content hashes, identities and replication cursors.

`CollaborationContent` represents a live cut. A local/incoming cut containing a
PAGE/document/state/board source whose owner is absent from the final catalog
fails with `addressed_delivery_required` before content, context, or ACK publication.
Live-only publication preserves retained sources. Remote historical ink uses its
existing merger; new local ink on a removed board is rejected.

## Local scene read window

`readSpatialInkWindow` reads conservative `ink_surfaces` bounds and their derived
R-tree in one SQLite read snapshot. Accepted contacts keep their complete immutable
spans, including pinned/off-window sources and erasers affecting moved elements.
An expanded pen extent uses one streaming eraser query per surface; exact tiled
intersection rejects envelope gaps before action admission or body decoding.
This removes repeated per-pen eraser scans without a second journal or global cache.
An envelope can still scan unrelated metadata in gaps; the 100,000-candidate test
records that cost rather than treating a broad-phase query as exact selection.

Window coverage is not ownership completeness. Exceeding the existing action or
retained-material budget fails the read instead of publishing a partial scene.
Undo/Redo reads addressed history headers separately from render membership.
Record/query witnesses revalidate actual source dependencies, including changed
membership, without using an unrelated global workspace cursor as pixel identity.

Schema 25 rebuilds only the local bounds/index from accepted immutable bodies.
It preserves content hashes, action identities, upload progress and receipt state;
it does not repeat the historical ink-format conversion. `rows` and streaming
`forEachRow` share the same SQLite read allowance and value decoder.

## Verification

Core scenarios cover 100,000 unrelated actions, multiple manifest pages, old echo,
rollback, replay after commit, removed covers, immutable spans, and baseline
admission. These checks establish their scoped storage behavior; they do not
establish current installed-pair performance or unlimited journal retention.
See [verification](verification.md).
