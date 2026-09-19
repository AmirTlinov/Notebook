# Addressed agent ink and item lifecycle

`NotebookActionProjection` reads the spatial-ink root and the UUID subtrees named
by `appendInkStroke`. Apply and causal undo use the same projection; the receipt
retains the original UUIDs. Action existence is checked globally, so a UUID owned
by another cover cannot be reassigned to the board.

`CollaborationStore` validates and publishes the projection difference in its
existing transaction. Unread actions, order, and measured points remain intact.
Undo changes activity, preserving immutable spans. Exact retry returns the same
receipt. Creation undo separately checks later human content of created surfaces.

## Physical-owner lifecycle

`appendPage` uses `publishPageAppend`, as native landing does.
`deleteItem` uses the UI's `deleteWorkspaceItemContent`.
The command preserves presence, camera, and selected page. Store membership, not
the paint window, defines deletion scope. A nonempty board and the final working
item are rejected before writing.

Lifecycle inverse data uses immutable roots/parts in the existing blob store.
Ordered `{address,beforeHash?,afterHash?}` entries bind workspace and action.
First-before capture covers action content, excluding results, receipts, and context.
Original and restoration inverse streams are required delivery/snapshot/cloud
dependencies. Hash validity accompanies causal and domain validation.

`undoCollaborationAction` checks deletion existence, the complete placement register,
and notebook membership/order before restoring groups. Parent boards precede children.
Independent continuation of a parent preserves its group. Membership restoration
uses fresh causal versions; ordinary fields use conditional undo, preserving accepted
later PAGE/document/state/board content.

Creating and deleting an item in one action does not resurrect it on undo.
Undo of append removes only a birth still owned by that action; human-adopted pages
survive. The shared [read allowance](agent-command-read-allowance.md) remains unchanged.

The move/create → delete → undo-delete → undo-earlier chain follows complete placement
proofs. `action_field_restorations` links earlier inverse blobs so provenance survives
reopen, delivery, and derived-index rebuilding. Shared-dot payloads, dominance, and
canonical address/value are validated. Independent human ABA and losing concurrent
heads do not become an earlier action's property. There is no automatic basis refresh
or action replay.

See [retained sources](spatial-replication-contract.md#retained-sources-and-live-membership)
and [verification](verification.md). Large-owner creation protection and runtime
acceptance are separate from bounded append/undo storage checks.
