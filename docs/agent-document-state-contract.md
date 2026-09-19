# Addressed agent state updates

`NotebookActionProjection` selects the document header, interactive programs named
by `setBlockState`, and state records with the same IDs. UUID-like IDs follow the
existing normalization; `/` and `~` are escaped in SQL addresses only.
The header retains complete source and state revisions.

`CollaborationWorkspace` requires an interactive block, exact `revision` and
`stateRevision`, and valid JSON. Updating state leaves source clocks and causal
source fields unchanged.

`CollaborationStore` publishes the baseline projection difference through
`NotebookStore.writeFragment`. Unread states, including retired program records,
are preserved. Content, receipt, context, and cursor commit atomically.
Undo restores the addressed program's previous value, or its initial state when
undoing its first write, while preserving later human edits. Repeating the UUID
returns the original receipt.

## Verification and limits

`NotebookAgentDocumentStateProjectionTests` exercises apply/undo/retry among
100,000 historical states, with corrupted unrelated records and a large unrelated
source. It checks stale revisions, human continuation, rollback, and ambiguous
post-commit responses. SQL accounting includes flush and commit.

Source changes, block ordering, and creation undo have separate contracts.
Creation undo intentionally checks the owner's later human work before removal.
This addressed-state contract does not establish full UI or installed-pair acceptance.
See [verification](verification.md).
