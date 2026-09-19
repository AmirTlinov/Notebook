# State delivery by block address

`DocumentStateJournal` stores values by `DocumentStateRecord.id`, including retained
states of removed programs. Its array is a canonical ID-ordered view, not user order.
Adding a record does not renumber existing physical rows.

`NotebookReplicationStore.applyReplicatedDocumentState` scans incoming addresses
in pages of 64 and tracks affected block IDs in a temporary SQL index. It reads
the journal header and each named subtree through point/range queries.
Similar IDs and escaped `/` or `~` remain distinct; nested JSON collections remain
program content.

`DocumentStateRecord.replace` owns version comparison, human continuation, and
observed clocks. Only changed values participate in aggregate selection. A newly
combined visible state advances the aggregate once; unchanged implicit versions
are not materialized in bulk.

`publishProjectionEdits` publishes each block difference through `writeFragment`.
Unread states remain intact. Invalid addresses, owners, collections, or unattached
subtrees reject the complete transaction. Records, receipt, delivery journal,
and incoming cursor commit together; exact retry resolves an ambiguous commit.

An admitted typed source/state pair can receive late fields after catalog removal
without restoring the document. See
[retained sources](spatial-replication-contract.md#retained-sources-and-live-membership).

## Pinned program state

`AgentPinnedSource.capture` uses the same `memberIdentity` as block-version
validation. It pins only the selected program's source and state. Later changes
invalidate a stale reference but do not rewrite an existing pin.
An absent record remains absent; the initial value belongs to the block.
Previously archived references remain immutable.

## Verification

Scenarios cover large state collections, unrelated corrupted bodies, nested JSON,
similar IDs, causal conflicts, human continuation, cursor atomicity, and replay.
Native publication and agent commands share these domain rules but have their own
[command](native-document-state-command.md) and [agent](agent-document-state-contract.md)
contracts. Historical results are in [verification](verification.md).
