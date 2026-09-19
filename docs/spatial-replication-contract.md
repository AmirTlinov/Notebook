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

`CollaborationContent` represents a live cut. A local/incoming cut containing a
PAGE/document/state/board source whose owner is absent from the final catalog
fails with `addressed_delivery_required` before content, context, or ACK publication.
Live-only publication preserves retained sources. Remote historical ink uses its
existing merger; new local ink on a removed board is rejected.

## Verification

Core scenarios cover 100,000 unrelated actions, multiple manifest pages, old echo,
rollback, replay after commit, removed covers, immutable spans, and baseline
admission. These checks establish their scoped storage behavior; they do not
establish current installed-pair performance or unlimited journal retention.
See [verification](verification.md).
