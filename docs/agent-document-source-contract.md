# Addressed program-source edits and causal versions

`NotebookActionProjection` reads the document header, the program IDs named by
`updateBlock`, and the exact causal fields needed by `setPreamble`. Deleted
program history is outside that projection. State commands use their addressed
path; a mixed package retains one operation order and one transaction.

`NotebookStore.boundedStoredFragments` admits SQL-indexed lengths before decoding.
All partial documents in a package share 4,096 fragments and 4 MiB. Reads belong
to one WAL snapshot. A missing blob is corruption; overlapping requests are rejected.
`NotebookDocumentBlockRead` uses the same owner. SQL addresses escape `/` and
`~`, preserve Unicode, and normalize UUIDs.

## Publication

A partial document grants no authority to replace unread content.
`CollaborationStore.publishProjectionEdits` publishes the baseline-to-edit
difference. Unaffected block positions, sources, and states remain unchanged.
Creation still requires a complete initial owner. Membership/order changes and
whole-document replacement use their full-input path and the same difference publisher.

When a program body is delivered, unchanged fields retain their original author
versions. Both publishers use `fieldKey`, including escaped IDs; unchanged causal
rows enter the manifest without rewriting the body. This prevents old CSS from
acquiring a recipient's newer version and overwriting an independent edit.
`DocumentDocument.sourceVersion` follows the storage owner's UUID normalization.

Existing materialized fields and undo do not read neighboring history. Creating
a previously implicit field checks the collection count through the SQL index.
That count remains proportional to row count; it is not claimed to be constant-time.

## Verification

`NotebookAgentDocumentSourceProjectionTests` checks apply, receipt, undo, retry,
unread-source preservation, positions, escaped IDs, concurrent CSS, multiple
documents sharing one allowance, and failures around commit. Fixtures include
99,000 historical causal fields and corrupted unrelated bodies.
A human change that returns to an earlier value still protects that accepted edit
from agent undo.

These are command/storage guarantees. Installation, physical rendering, delivery
retention, and live user MCP acceptance have separate evidence in
[verification](verification.md).
