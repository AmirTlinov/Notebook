# Addressed document-source delivery

`NotebookStore.applyReplicatedDocumentSource` passes one program at a time to
`DocumentDocument.merge`. Causal history is read in pages of 64 addresses.
Ordering reads at most 512 index rows and uses the same `contentMemberOrder`
as a full merge. `DocumentBlock` defines causal field names for delivery and
agent commands alike.

## Admission and complete declarations

Incoming and stored program sources are admitted before decoding: 4,096 fragments
and 16 MiB each. The merged value must also fit. Headers are limited to 1 MiB and
causal versions to 64 KiB. A newly materialized causal field checks the owner's
100,000-field bound; that occasional SQL count remains proportional to history.

Changing a source fragment marks its program in the existing transaction-local SQL
table. Before publishing a manifest, the writer enumerates the complete current
subtree and its seven causal fields in pages of 64 hashes. Unchanged bodies are
referenced rather than rewritten. An order change declares all author positions,
including positions that only changed at the receiver.

`initialState` is one authored value. Arbitrary JSON keys such as `records`,
`blocks`, or `collaboration.fields` do not grant storage structure.
The receiver merges a complete declared program against its local causal fields.
A child mutation without that declaration is rejected; unrelated programs remain
unchanged.

Complete declarations were introduced with manifest 3. That historical transition
is not the current wire version; see [transport](transport-contract.md).
Unsupported manifests are rejected rather than interpreted as complete programs.

## Snapshot and retained-source boundaries

`prepareDeviceSnapshot` can rebuild delivery from current records while preserving
content hashes, questions, receipts, and stopped runs. A newly prepared journal
starts at sequence 1 with no copied network acknowledgements. A continuing device
preserves its local drafts/jobs; another device has independent presence.
This belongs to the explicit snapshot/transfer route, not normal application startup.

Admitted source/state baselines survive catalog removal and accept late causal fields
without restoring live membership. See
[retained sources](spatial-replication-contract.md#retained-sources-and-live-membership).

## Verification

Tests cover 99,000 unrelated fields, independent CSS, human continuation, removals,
ordering, nested initial state, escaped IDs, resource limits before decoding,
rollback, exact retry, and real exchange between prepared stores.
These storage checks do not establish physical display, source-editor acceptance,
or general blob garbage collection. Evidence is in [verification](verification.md).
